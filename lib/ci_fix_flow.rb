# frozen_string_literal: true
# Flusso di fix CI (calvin-fix).
# Pipeline dry-transaction con 6 step espliciti:
#
#   classify      — classifica l'errore (:structural | :logical | :infra)
#   build_prompt  — FixPromptBuilder costruisce il prompt
#   call_mistral  — chiamata Codestral
#   parse_files   — estrae FILE: blocks
#   commit_fix    — committa il fix sul branch della PR
#   post_comment  — posta commento su PR
#
# Ritorna:
#   Success({ status: :fixed, usage: })
#   Failure({ step:, error:, status: :unfixable | :error, usage: })

require "dry/transaction"
require_relative "fix_prompt_builder"
require_relative "file_parser"
require_relative "mistral_client"

module Calvin
  class CiFixFlow
    include Dry::Transaction

    STRUCTURAL_PATTERNS = [
      /NameError.*uninitialized constant/,
      /LoadError.*cannot load such file/,
      /ActiveRecord::RecordNotFound/,
      /PG::UndefinedColumn/,
      /PG::UndefinedTable/,
      /ActiveRecord::PendingMigrationError/
    ].freeze

    LOGICAL_PATTERNS = [
      /Expected .+ got/,
      /assert.*failed/i,
      /ArgumentError/,
      /StandardError.*fixture/i,
      /\d+ runs,.*\d+ failures/
    ].freeze

    step :classify
    step :build_prompt
    step :call_mistral
    step :parse_files
    step :commit_fix
    step :post_comment

    def self.run(github, pr_number, pr_branch, test_output)
      new.call(github: github, pr_number: pr_number, pr_branch: pr_branch, test_output: test_output)
    end

    private

    def classify(github:, pr_number:, pr_branch:, test_output:)
      error_type = detect_error_type(test_output)
      Calvin::LOG.info "CiFixFlow: tipo errore — #{error_type}"

      if error_type == :structural
        Success(github: github, pr_number: pr_number, pr_branch: pr_branch, test_output: test_output)
      else
        github.post_pr_comment(pr_number, <<~MD)
          ⚠️ **Calvin Fix: errore non fixabile automaticamente.**

          Tipo rilevato: `#{error_type}` — richiede intervento manuale.
          Leggi lo stacktrace nel commento precedente.
        MD
        Failure(step: :classify, error: "errore #{error_type} non fixabile", status: :unfixable, usage: nil)
      end
    end

    def build_prompt(github:, pr_number:, pr_branch:, test_output:)
      prompt = FixPromptBuilder.build(test_output: test_output, github: github)
      Success(github: github, pr_number: pr_number, pr_branch: pr_branch, prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, status: :error, usage: nil)
    end

    def call_mistral(github:, pr_number:, pr_branch:, prompt:)
      result = MistralClient.new.complete(prompt)
      Success(github: github, pr_number: pr_number, pr_branch: pr_branch, content: result[:content], usage: result[:usage])
    rescue => e
      Failure(step: :call_mistral, error: e.message, status: :error, usage: nil)
    end

    def parse_files(github:, pr_number:, pr_branch:, content:, usage:)
      files = FileParser.parse(content)
      if files.empty?
        Calvin::LOG.warn "CiFixFlow: nessun FILE: block prodotto da Codestral"
        github.post_pr_comment(pr_number, "❌ Calvin Fix: Codestral non ha prodotto file.")
        return Failure(step: :parse_files, error: "nessun FILE: block", status: :error, usage: usage)
      end
      Success(github: github, pr_number: pr_number, pr_branch: pr_branch, files: files, usage: usage)
    end

    def commit_fix(github:, pr_number:, pr_branch:, files:, usage:)
      github.commit_files_atomically(
        files,
        message: "fix: CI fix via Calvin — PR ##{pr_number}",
        branch:  pr_branch
      )
      Calvin::LOG.info "CiFixFlow: fix committato su #{pr_branch}"
      Success(github: github, pr_number: pr_number, usage: usage)
    rescue => e
      Failure(step: :commit_fix, error: e.message, status: :error, usage: usage)
    end

    def post_comment(github:, pr_number:, usage:)
      github.post_pr_comment(pr_number,
        "✅ **Calvin Fix applicato.** Push su branch — attendi la CI."
      )
      Success(status: :fixed, usage: usage)
    rescue => e
      Calvin::LOG.warn "post_comment FAILED (non bloccante): #{e.message}"
      Success(status: :fixed, usage: usage)
    end

    def detect_error_type(output)
      return :structural if STRUCTURAL_PATTERNS.any? { |p| output.match?(p) }
      return :logical    if LOGICAL_PATTERNS.any? { |p| output.match?(p) }
      :infra
    end
  end
end
