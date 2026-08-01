# frozen_string_literal: true
# Calvin::PostSteps — step uniformi eseguiti dopo ogni flow.
#
# Responsabilità:
#   1. RubocopAutocorrect sui file prodotti dal flow (solo su successo — rete di
#      sicurezza: dopo il fix dell'ordine del gate rubocop in Validator, di norma non
#      trova più nulla da correggere)
#   2. RunReporter.write — log CSV nel repo target
#   3. post_status sull'issue in caso di failure (se issue disponibile)
#
# I test generati (TestGenerator, vedi ExploreFlow#generate_tests) entrano nel batch
# PRIMA della validazione: il loro esito è già dentro validation_stage/validation_ok
# riportati da RunReporter, e nel body della PR (PrBodyBuilder.validation_section) —
# nessun commento separato da postare qui.
#
# Compatibile con qualsiasi flow che restituisce Calvin::FlowResult.
# I campi opzionali (explore_turns, ecc.) vengono letti
# via FlowResult#meta(:key) — nil-safe, senza KeyError.
#
# Uso:
#   Calvin::PostSteps.run(
#     result,
#     github:   github,
#     mistral:  mistral,
#     workflow: "calvin",
#     ref:      issue.number,
#     issue:    issue          # opzionale — usato per post_status su failure
#   )

module Calvin
  module PostSteps
    def self.run(result, github:, mistral:, workflow:, ref:, issue: nil)
      if result.success?
        r = result.value!  # Calvin::FlowResult

        unless Calvin.dry_run?
          Calvin::RubocopAutocorrect.run(
            files:  r.files  || [],
            branch: r.branch || "",
            github: github
          )
        end

        Calvin::RunReporter.write(
          github:           github,
          workflow:         workflow,
          ref:              ref,
          model:            Calvin::MODEL,
          usage:            r.usage,
          status:           r.status,
          explore_turns:    r.meta(:explore_turns),
          temperature:      r.temperature,
          files_written:    Array(r.files).size,
          issue_length:     issue&.body.to_s.length,
          validation_stage: r.meta(:validation_stage),
          validation_ok:    r.meta(:validation_ok),
          repair_attempts:  r.meta(:repair_attempts),
          knowledge:        r.meta(:knowledge)
        )
      else
        err = result.failure
        Calvin::LOG.error "FAILURE step=#{err[:step]} — #{err[:error]}"

        if issue
          begin
            github.post_status(
              issue,
              "\u{1F534} Calvin error (#{err[:step]})\n\n```\n#{err[:error]}\n```"
            )
          rescue => e
            Calvin::LOG.warn "post_status fallito: #{e.message}"
          end
        end

        Calvin::RunReporter.write(
          github:        github,
          workflow:      workflow,
          ref:           ref,
          model:         Calvin::MODEL,
          usage:         err[:usage],
          status:        err[:status] || :failure,
          explore_turns: err[:explore_turns],
          temperature:   err[:temperature],
          files_written: nil,
          issue_length:  issue&.body.to_s.length
        )
      end
    end
  end
end
