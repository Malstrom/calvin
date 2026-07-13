# frozen_string_literal: true
# Parsea la risposta del modello ed estrae i blocchi FILE: e il PR body.
#
# Formati FILE: block supportati (entrambi validi):
#
#   Formato con fence (vecchio):
#     FILE: path/to/file.rb
#     ```ruby
#     # contenuto completo
#     ```
#
#   Formato senza fence (attuale — implement_system dice "no markdown fences"):
#     FILE: path/to/file.rb
#     # contenuto completo
#     <riga vuota o prossimo FILE: o PR_BODY_START o fine stringa>
#
# Formato PR body:
#
#   PR_BODY_START
#   ... markdown ...
#   PR_BODY_END
#
# .parse(content)         → Array<{ path: String, content: String }>
# .parse_pr_body(content) → String | nil

module Calvin
  class FileParser
    # Formato con backtick fence: FILE: path\n```(lang)?\ncontent\n```
    FILE_BLOCK_FENCED = /^FILE:\s*(.+?)\n```[\w]*\n(.*?)^```/m

    # Formato senza fence: FILE: path\ncontent\n (fino al prossimo FILE:, PR_BODY_START, o fine stringa)
    FILE_BLOCK_PLAIN  = /^FILE:\s*(.+?)\n(.*?)(?=^FILE:|^PR_BODY_START|\z)/m

    PR_BODY_BLOCK = /^PR_BODY_START\s*\n(.*?)\nPR_BODY_END/m

    # Test generation disabled — Calvin does not yet write reliable tests.
    # Remove this filter once test quality is validated.
    # SKIP_PATTERN = %r{^test/}

    def self.parse(content)
      # Prova prima il formato con fence
      fenced = content.scan(FILE_BLOCK_FENCED).map do |path, file_content|
        { path: path.strip, content: file_content }
      end
      return fenced if fenced.any?

      # Fallback: formato senza fence
      content.scan(FILE_BLOCK_PLAIN).map do |path, file_content|
        { path: path.strip, content: file_content.rstrip }
      end
    end

    def self.parse_pr_body(content)
      match = content.match(PR_BODY_BLOCK)
      match&.captures&.first&.strip
    end
  end
end
