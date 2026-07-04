# frozen_string_literal: true
# Parsea la risposta di Codestral ed estrae i blocchi FILE:.
#
# Formato atteso nella risposta:
#
#   FILE: path/to/file.rb
#   ```ruby
#   # contenuto completo
#   ```
#
# .parse(content) → Array<{ path: String, content: String }>

module Calvin
  class FileParser
    # Matches: FILE: path\n```(lang)?\ncontent\n```
    FILE_BLOCK = /^FILE:\s*(.+?)\n```[\w]*\n(.*?)^```/m

    def self.parse(content)
      content.scan(FILE_BLOCK).map do |path, file_content|
        { path: path.strip, content: file_content }
      end
    end
  end
end
