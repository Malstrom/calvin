# frozen_string_literal: true
# Parsea la risposta di Codestral ed estrae i blocchi FILE: e il PR body.
#
# Formato FILE: blocks:
#
#   FILE: path/to/file.rb
#   ```ruby
#   # contenuto completo
#   ```
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
    # Matches: FILE: path\n```(lang)?\ncontent\n```
    FILE_BLOCK    = /^FILE:\s*(.+?)\n```[\w]*\n(.*?)^```/m
    PR_BODY_BLOCK = /^PR_BODY_START\s*\n(.*?)\nPR_BODY_END/m

    def self.parse(content)
      content.scan(FILE_BLOCK).map do |path, file_content|
        { path: path.strip, content: file_content }
      end
    end

    def self.parse_pr_body(content)
      match = content.match(PR_BODY_BLOCK)
      match&.captures&.first&.strip
    end
  end
end
