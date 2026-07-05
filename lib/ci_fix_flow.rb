# frozen_string_literal: true
# Flusso di fix CI (calvin-fix).
# Pipeline dry-transaction con 5 step espliciti:
#
#   classify      — classifica l'errore (:structural | :logical | :infra)
#   build_prompt  — FixPromptBuilder costruisce il prompt
#   call_mistral  — chiamata Codestral
#   parse_files   — estrae FILE: blocks
#   commit_fix    — committa il fix sul branch della PR
#   post_comment  — posta commento ✅ sulla PR
#
# Nota: remove_fix_label è chiamato in ensure dall'orchestratore (calvin.rb),
# non dentro questo flow — deve girare anche in caso di Failure.
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

    def initialize(github, pr_number, pr_branch, test_output)
      @github      = github
      @pr_number   = pr_number
      @pr_branch   = pr_branch
      @test_output = test_output
      @usage       = nil
      super()
    end

    attr_reader :usage

    private

    def classify(_input)
      error_type = detect_error_type(@test_output)
      Calvin::LOG.info "CiFixFlow: tipo errore — #{error_type}"

      if error_type == :structural
        Success({})
      else
        @github.post_pr_comment(@pr_number, <<~MD)
          ⚠️ **Calvin Fix: errore non fixabile automaticamente.**

          Tipo rilevato: `#{error_type}` — richiede intervento manuale.
          Leggi lo stacktrace nel commento precedente.
        MD
        Failure(step: :classify, error: "errore #{error_type} non fixabile", status: :unfixable, usage: nil)
      end
    end

    def build_prompt(_input)
      prompt = FixPromptBuilder.build(test_output: @test_output, github: @github)
      Success(prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, status: :error, usage: nil)
    end

    def call_mistral(prompt:)
      result = MistralClient.new.complete(prompt)
      @usage = result[:usage]
      Success(content: result[:content], usage: result[:usage])
    rescue => e
      Failure(step: :call_mistral, error: e.message, status: :error, usage: @usage)
    end

    def parse_files(content:, usage:)
      files = FileParser.parse(content)
      if files.empty?
        Calvin::LOG.warn "CiFixFlow: nessun FILE: block prodotto da Codestral"
        @github.post_pr_comment(@pr_number, "❌ Calvin Fix: Codestral non ha prodotto file.")
        return Failure(step: :parse_files, error: "nessun FILE: block", status: :error, usage: usage)
      end
      Success(files: files, usage: usage)
    end

    def commit_fix(files:, usage:)
      @github.commit_files_atomically(
        files,
        message: "fix: CI fix via Calvin — PR ##{@pr_number}",
        branch:  @pr_branch
      )
      Calvin::LOG.info "CiFixFlow: fix committato su #{@pr_branch}"
      Success(usage: usage)
    rescue => e
      Failure(step: :commit_fix, error: e.message, status: :error, usage: usage)
    end

    def post_comment(usage:)
      @github.post_pr_comment(@pr_number,
        "✅ **Calvin Fix applicato.** Push su `#{@pr_branch}` — attendi la CI."
      )
      Success(status: :fixed, usage: usage)
    rescue => e
      # Non bloccante: il fix è già committato
      Calvin::LOG.warn "post_comment FAILED (non bloccante): #{e.message}"
      Success(status: :fixed, usage: usage)
    end

    # In caso di dubbio → :logical (conservativo)
    def detect_error_type(output)
      return :structural if STRUCTURAL_PATTERNS.any? { |p| output.match?(p) }
      return :logical    if LOGICAL_PATTERNS.any? { |p| output.match?(p) }
      :infra
    end
  end
end
