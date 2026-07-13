# frozen_string_literal: true
# Calvin::PostSteps — step uniformi eseguiti dopo ogni flow.
#
# Responsabilità:
#   1. TestFlow sui file prodotti dal flow (solo su successo, prima di rubocop)
#   2. RubocopAutocorrect sui file prodotti dal flow (solo su successo)
#   3. RunReporter.write — log CSV/MD nel repo target
#   4. post_status sull'issue in caso di failure (se issue disponibile)
#
# Compatibile con qualsiasi flow che restituisce Calvin::FlowResult.
# I campi opzionali (explore_turns, test_pass_pct, ecc.) vengono letti
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

require_relative "test_flow"

module Calvin
  module PostSteps
    def self.run(result, github:, mistral:, workflow:, ref:, issue: nil)
      if result.success?
        r = result.value!  # Calvin::FlowResult

        source_paths = Array(r.files).map { |f| f[:path] }
        TestFlow.call(source_paths, github: github, mistral: mistral)

        Calvin::RubocopAutocorrect.run(
          files:  r.files  || [],
          branch: r.branch || "",
          github: github
        )

        Calvin::RunReporter.write(
          github:        github,
          workflow:      workflow,
          ref:           ref,
          model:         Calvin::MODEL,
          usage:         r.usage,
          status:        r.status,
          explore_turns: r.meta(:explore_turns),
          test_pass_pct: r.meta(:test_pass_pct),
          temperature:   r.temperature,
          files_written: Array(r.files).size,
          issue_length:  issue&.body.to_s.length
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
          test_pass_pct: err[:test_pass_pct],
          temperature:   err[:temperature],
          files_written: nil,
          issue_length:  issue&.body.to_s.length
        )
      end
    end
  end
end
