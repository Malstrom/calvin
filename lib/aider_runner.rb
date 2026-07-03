# frozen_string_literal: true
# Wrapper per Aider CLI.
#
# --no-auto-commits: Aider scrive i file ma non committa.
# Calvin fa git add + commit + push dopo rubocop.
#
# .apply(prompt) → Success({ stdout:, tokens: }) | Failure(stderr)

require "open3"
require "dry/monads"

module Calvin
  class AiderRunner
    include Dry::Monads[:result]

    AIDER_MODEL = "codestral/codestral-latest"

    # Scansiona solo la cartella backend/api dove vive la maggior parte
    # del codice Rails. Riduce la repo-map da ~4000 a ~1000 token.
    SUBTREE_DIR = "backend/api"

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

      full_message = "#{SYSTEM_PROMPT}\n---\n#{prompt}"

      cmd = [
        "aider",
        "--model",           AIDER_MODEL,
        "--yes",
        "--no-auto-lint",
        "--no-auto-commits",
        "--subtree-only",
        "--map-tokens",      "2000",
        "--message",         full_message
      ]

      Calvin::LOG.info "Running aider (#{AIDER_MODEL}, subtree: #{SUBTREE_DIR})..."
      stdout, stderr, status = Open3.capture3(env, *cmd, chdir: SUBTREE_DIR)
      Calvin::LOG.info stdout.slice(0, 3_000) unless stdout.empty?
      Calvin::LOG.warn stderr.slice(0, 1_000) unless stderr.empty?

      if status.success?
        Success({ stdout: stdout, tokens: extract_tokens(stdout) })
      else
        Failure("Aider fallito (exit #{status.exitstatus}):\n#{stderr.slice(0, 2_000)}")
      end
    end

    private

    # Estrae i token dall'ultima riga di riepilogo di Aider.
    # Formato tipico: "Tokens: 1234 sent, 567 received. Cost: $0.0089"
    def extract_tokens(text)
      line = text.lines.reverse.find { |l| l.match?(/Tokens:/i) }
      return {} unless line

      sent     = line.match(/([\d,]+)\s*sent/)&.captures&.first&.delete(",")&.to_i
      received = line.match(/([\d,]+)\s*received/)&.captures&.first&.delete(",")&.to_i
      cost_str = line.match(/Cost:\s*\$?([\d.]+)/)&.captures&.first

      { sent: sent.to_i, received: received.to_i, cost_usd: cost_str&.to_f }
    end
  end
end
