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
#
# Nota: i file sotto test/ e spec/ vengono scartati automaticamente come
# safety net — i test sono gestiti in una fase separata.

module Calvin
  class FileParser
    # Formato con backtick fence: FILE: path\n```(lang)?\ncontent\n```
    FILE_BLOCK_FENCED = /^FILE:\s*(.+?)\n```[\w]*\n(.*?)^```/m

    # Formato senza fence: FILE: path\ncontent\n (fino al prossimo FILE:, PR_BODY_START, o fine stringa)
    FILE_BLOCK_PLAIN  = /^FILE:\s*(.+?)\n(.*?)(?=^FILE:|^PR_BODY_START|\z)/m

    PR_BODY_BLOCK = /^PR_BODY_START\s*\n(.*?)\nPR_BODY_END/m

    # Percorsi test da escludere sempre — i test sono generati in una fase separata.
    TEST_PATH_PREFIXES = %w[test/ spec/].freeze

    def self.parse(content)
      files = parse_raw(content)
      files.reject { |f| TEST_PATH_PREFIXES.any? { |prefix| f[:path].start_with?(prefix) } }
    end

    def self.parse_pr_body(content)
      match = content.match(PR_BODY_BLOCK)
      match&.captures&.first&.strip
    end

    private_class_method def self.parse_raw(content)
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
  end
end
