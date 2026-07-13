# frozen_string_literal: true
# Calvin::PostSteps — step uniformi eseguiti dopo ogni flow.
#
# Responsabilità:
#   1. TestFlow sui file prodotti dal flow (solo su successo, prima di rubocop)
#      → posta un commento sulla PR con le stats dei test
#   2. RubocopAutocorrect sui file prodotti dal flow (solo su successo)
#   3. RunReporter.write — log CSV nel repo target
#   4. post_status sull'issue in caso di failure (se issue disponibile)
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

require_relative "test_flow"

module Calvin
  module PostSteps
    def self.run(result, github:, mistral:, workflow:, ref:, issue: nil)
      if result.success?
        r = result.value!  # Calvin::FlowResult

        source_paths = Array(r.files).map { |f| f[:path] }
        tf = TestFlow.call(source_paths, github: github, mistral: mistral)

        if tf.success? && r.respond_to?(:pr_number) && r.pr_number
          stats = tf.value!
          post_test_comment(github, r.pr_number, stats) if stats[:tests_written] > 0 || stats[:writer_errors] > 0
        end

        Calvin::RubocopAutocorrect.run(
          files:  r.files  || [],
          branch: r.branch || "",
          github: github
        )

        tests_written = tf.success? ? tf.value![:tests_written] : nil
        writer_errors = tf.success? ? tf.value![:writer_errors] : nil

        Calvin::RunReporter.write(
          github:        github,
          workflow:      workflow,
          ref:           ref,
          model:         Calvin::MODEL,
          usage:         r.usage,
          status:        r.status,
          explore_turns: r.meta(:explore_turns),
          tests_written: tests_written,
          writer_errors: writer_errors,
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
          tests_written: nil,
          writer_errors: nil,
          temperature:   err[:temperature],
          files_written: nil,
          issue_length:  issue&.body.to_s.length
        )
      end
    end

    # ── private ───────────────────────────────────────────────────────────────

    def self.post_test_comment(github, pr_number, stats)
      written = stats[:tests_written]
      errors  = stats[:writer_errors]
      skipped = stats[:tests_skipped]

      error_row = errors > 0 ? "| ❌ errori writer | #{errors} |\n" : ""

      body = <<~MD
        ### 🧪 Test generation
        | | |
        |---|---|
        | ✅ test scritti | #{written} |
        #{error_row}| ⏭️ saltati (non testabili) | #{skipped} |

        _I test sono stati generati da Calvin ma non eseguiti — verifica manuale necessaria._
      MD

      github.post_pr_comment(pr_number, body.strip)
    rescue => e
      Calvin::LOG.warn "PostSteps: post_test_comment fallito — #{e.message}"
    end
    private_class_method :post_test_comment
  end
end
