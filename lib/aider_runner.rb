# frozen_string_literal: true
# Wrapper per Aider CLI.
#
# --no-auto-commits: Aider scrive i file ma non committa.
# Calvin fa git add + commit + push dopo i test verdi.
#
# .apply(prompt) → Success(:aider_done) | Failure(stderr)

require "open3"
require "dry/monads"

module Calvin
  class AiderRunner
    include Dry::Monads[:result]

    AIDER_MODEL = "codestral/codestral-latest"

    # Sei un assistente Rails senior specializzato nell'implementare
    # feature in codebase Rails esistenti. Segui le istruzioni del prompt
    # alla lettera senza aggiungere codice non richiesto.
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a senior Rails developer working on an existing Rails codebase.
      Implement exactly what is described in the task.
      Follow existing conventions, naming patterns, and code style.
      Do not add unrequested files, specs, or comments.
      Write clean, idiomatic Ruby. Prefer simple solutions over clever ones.
    PROMPT

    def initialize(api_key: ENV.fetch("MISTRAL_API_KEY"))
      @api_key = api_key
    end

    def apply(prompt)
      env = { "CODESTRAL_API_KEY" => @api_key }

      cmd = [
        "aider",
        "--model",           AIDER_MODEL,
        "--yes",
        "--no-auto-lint",
        "--no-auto-commits",
        "--system-prompt",   SYSTEM_PROMPT,
        "--message",         prompt
      ]

      Calvin::LOG.info "Running aider (#{AIDER_MODEL})..."
      stdout, stderr, status = Open3.capture3(env, *cmd)
      Calvin::LOG.info stdout unless stdout.empty?
      Calvin::LOG.warn stderr unless stderr.empty?

      status.success? ? Success(:aider_done) : Failure("Aider fallito (exit #{status.exitstatus}):\n#{stderr.slice(0, 2_000)}")
    end
  end
end
