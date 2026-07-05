# frozen_string_literal: true
# Costruisce il prompt minimale per il fix dei test falliti.
#
# Legge i file sorgente dal branch della PR (non dal default branch),
# così il modello vede il codice che Calvin ha appena scritto, non main.
#
# Output: { system: String, prompt: String }
# Target: ~2000-3000 token, non l'intero output di `rails test`.
#
# Uso:
#   result = Calvin::TestFixPromptBuilder.build(
#     failures:      result[:failures],
#     github:        github_client,   # con repo_root già impostato per synca
#     branch:        "auto/issue-42-123",
#     system_prompt: File.read("config/prompts/rails/fix_test_system.md")
#   )
#   result[:system]  # => String (system message per Codestral)
#   result[:prompt]  # => String (user message con failures + sorgenti)

module Calvin
  module TestFixPromptBuilder
    SCHEMA_PATH = "db/schema.rb"

    def self.build(failures:, github:, branch:, system_prompt:)
      sections = []

      # 1. Blocchi failure
      sections << "## Test failures\n"
      failures.each_with_index do |f, i|
        sections << "### Failure #{i + 1}\n"
        sections << "```\n#{f[:message]}\n```\n"
        sections << "Test file: `#{f[:test_path]}`\n"
        sections << "Impl file: `#{f[:impl_path]}`\n" if f[:impl_path]
      end

      # 2. Contenuto dei file coinvolti — letti dal branch della PR, non da main.
      # Senza ref: branch, il modello riceverebbe il codice vecchio e potrebbe
      # ri-introdurre gli stessi errori che Calvin ha appena "fixato".
      file_paths = failures.flat_map { |f| [f[:test_path], f[:impl_path]] }.compact.uniq
      if file_paths.any?
        sections << "\n## Source files (branch: #{branch})\n"
        file_paths.each do |path|
          content = github.get_file_content(path, ref: branch)
          next unless content
          ext = File.extname(path).sub(".", "")
          sections << "### `#{path}`\n```#{ext}\n#{content}\n```\n"
        end
      end

      # 3. Schema come anchor (evita timestamp inventati, colonne errate)
      schema = github.get_file_content(SCHEMA_PATH, ref: branch)
      if schema
        sections << "\n## db/schema.rb (reference only — do not modify)\n"
        sections << "```ruby\n#{schema}\n```\n"
      end

      prompt = sections.join("\n")

      Calvin::LOG.info "TestFixPromptBuilder: prompt #{prompt.length} chars / ~#{(prompt.length / 4.0).round} token(s) stimati"

      { system: system_prompt, prompt: prompt }
    end
  end
end
