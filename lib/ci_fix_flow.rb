# frozen_string_literal: true
# Flusso di fix CI.
#
# Riceve l'output dei test falliti, classifica il tipo di errore,
# e se strutturale chiama Codestral con un prompt mirato.
# Un solo tentativo. Rimuove sempre la label calvin-fix alla fine.
#
# Classificazione errori:
#   :structural — NameError, LoadError, fixture missing, PG::Undefined*
#   :logical    — Expected X got Y, assertion failures
#   :infra      — timeout, crash infrastruttura
#
# In caso di dubbio → :logical (conservativo: meglio fermarsi che peggiorare).
#
# Riuso componenti esistenti:
#   MistralClient#complete   — chiamata Codestral
#   FileParser.parse         — estrae FILE: blocks dalla risposta
#   GitHubClient#get_file_content         — legge file sorgente dal branch
#   GitHubClient#commit_files_atomically  — committa il fix
#   GitHubClient#post_pr_comment          — posta commento sulla PR
#   GitHubClient#remove_label             — rimuove label calvin-fix
#
# .run → :fixed | :unfixable | :error

require_relative "file_parser"
require_relative "mistral_client"

module Calvin
  class CiFixFlow
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
      /\d+ runs,.*\d+ failures/
    ].freeze

    def initialize(github, pr_number, pr_branch, test_output)
      @github      = github
      @pr_number   = pr_number
      @pr_branch   = pr_branch
      @test_output = test_output
    end

    def run
      error_type = classify_error(@test_output)
      Calvin::LOG.info "Tipo errore CI: #{error_type}"

      if error_type == :structural
        attempt_fix
      else
        post_unfixable_comment(error_type)
        :unfixable
      end
    ensure
      remove_fix_label
    end

    private

    # In caso di dubbio → :logical (conservativo)
    def classify_error(output)
      return :structural if STRUCTURAL_PATTERNS.any? { |p| output.match?(p) }
      return :logical    if LOGICAL_PATTERNS.any? { |p| output.match?(p) }
      :infra
    end

    # Estrae i blocchi Failure/Error dallo stacktrace Minitest.
    # Dal primo "N) Failure/Error:" fino alla riga summary "X runs,".
    def extract_error_blocks(output)
      blocks   = []
      current  = []
      in_block = false

      output.split("\n").each do |line|
        if line.match?(/^\s*\d+\) (Failure|Error):/)
          blocks << current.join("\n") if current.any?
          current  = [line]
          in_block = true
        elsif in_block
          if line.match?(/^\d+ runs,/)
            blocks << current.join("\n") if current.any?
            current  = []
            in_block = false
          else
            current << line
          end
        end
      end
      blocks << current.join("\n") if current.any?
      blocks.join("\n\n---\n\n")
    end

    # Estrae path dei file sorgente dallo stacktrace.
    # Esclude i file di test — il bug è nel sorgente, non nel test.
    def extract_source_files(output)
      output
        .scan(%r{(app/[\w/]+\.rb):\d+})
        .flatten
        .uniq
        .reject { |p| p.include?("test/") }
    end

    def build_fix_prompt(error_blocks, source_files)
      file_contents = source_files.filter_map do |path|
        content = @github.get_file_content(path)
        next unless content
        Calvin::LOG.info "injecting source file: #{path}"
        "---\n#{path}\n#{content}\n---"
      end.join("\n\n")

      <<~PROMPT
        La CI ha fallito con questi errori:

        #{error_blocks}

        #{file_contents.empty? ? '' : "Ecco i file sorgente coinvolti:\n\n#{file_contents}"}

        Correggi solo i file che causano l'errore.
        Rispondi nel formato FILE: solito.
      PROMPT
    end

    def attempt_fix
      error_blocks = extract_error_blocks(@test_output)
      source_files = extract_source_files(@test_output)
      Calvin::LOG.info "File sorgente: #{source_files.join(', ')}"

      prompt = build_fix_prompt(error_blocks, source_files)
      result = MistralClient.new.complete(prompt)
      files  = FileParser.parse(result[:content])

      if files.empty?
        Calvin::LOG.warn "Nessun FILE: block prodotto da Codestral"
        post_pr_comment("❌ Calvin Fix: Codestral non ha prodotto file.")
        return :error
      end

      @github.commit_files_atomically(
        files,
        message: "fix: CI fix via Calvin \u2014 PR ##{@pr_number}",
        branch:  @pr_branch
      )
      Calvin::LOG.info "Fix committato su #{@pr_branch}"
      post_pr_comment("✅ **Calvin Fix applicato.** Push su `#{@pr_branch}` \u2014 attendi la CI.")
      :fixed
    rescue => e
      Calvin::LOG.error "attempt_fix error: #{e.message}"
      post_pr_comment("❌ Calvin Fix fallito: `#{e.message}`")
      :error
    end

    def post_unfixable_comment(error_type)
      post_pr_comment(<<~MD)
        ⚠️ **Calvin Fix: errore non fixabile automaticamente.**

        Tipo rilevato: `#{error_type}` \u2014 richiede intervento manuale.\n        Leggi lo stacktrace nel commento precedente.
      MD
    end

    def post_pr_comment(body)
      @github.post_pr_comment(@pr_number, body)
    end

    def remove_fix_label
      @github.remove_label(@pr_number, "calvin-fix")
    rescue => e
      Calvin::LOG.warn "remove_fix_label: #{e.message}"
    end
  end
end
