# frozen_string_literal: true
# Calvin::PostSteps — step uniformi eseguiti dopo ogni flow.
#
# Responsabilità:
#   1. TestFlow sui file prodotti dal flow (solo su successo, prima di rubocop)
#      → posta un commento sulla PR con le stats dei test se pr_url disponibile
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
        # TestFlow disabled — generated tests are not reliable yet.
        # Re-enable when test generation quality improves.
        # tf = TestFlow.call(
        #   source_paths,
        #   branch:  r.branch || "",
        #   github:  github,
        #   mistral: mistral
        # )
        tf = Dry::Monads::Failure(:disabled)

        if tf.success?
          stats     = tf.value!
          pr_number = pr_number_from_url(r.pr_url)
          if pr_number && (stats[:tests_written] > 0 || stats[:writer_errors] > 0)
            post_test_comment(github, pr_number, stats)
          end
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

    # https://github.com/owner/repo/pull/123 → 123
    def self.pr_number_from_url(pr_url)
      return nil unless pr_url.to_s =~ %r{/pull/(\d+)}
      $1.to_i
    end
    private_class_method :pr_number_from_url

    def self.post_test_comment(github, pr_number, stats)
      body = Calvin::PrBodyBuilder.test_comment(
        stats[:tests_written],
        stats[:writer_errors],
        stats[:tests_skipped],
        usage:       stats[:usage_total],
        retrievals:  stats[:retrievals]
      )
      github.post_pr_comment(pr_number, body)
    rescue => e
      Calvin::LOG.warn "PostSteps: post_test_comment fallito — #{e.message}"
    end
    private_class_method :post_test_comment
  end
end
