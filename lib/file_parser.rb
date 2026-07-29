# frozen_string_literal: true
# Parsea la risposta del modello ed estrae i blocchi FILE: e il PR body.
#
# Formati FILE: block supportati, anche mescolati nella stessa risposta:
#
#   Con fence:
#     FILE: path/to/file.rb
#     ```ruby
#     # contenuto completo
#     ```
#
#   Senza fence (formato richiesto da implement_system.md):
#     FILE: path/to/file.rb
#     # contenuto completo
#     <prossimo FILE: | PR_BODY_START | fine stringa>
#
# Prima questa classe provava il formato fenced e, solo se non trovava nulla, quello plain
# (`return fenced if fenced.any?`): una risposta mista perdeva silenziosamente i blocchi
# dell'altro formato e Calvin committava un sottoinsieme dei file. Ora la scansione è
# unica e sequenziale, quindi i due formati convivono.
#
# Formato PR body:
#   PR_BODY_START
#   ... markdown ...
#   PR_BODY_END
#
# .parse(content)         → Array<{ path: String, content: String }>
# .parse_pr_body(content) → String | nil

module Calvin
  class FileParser
    # Header di un blocco: "FILE: path" a inizio riga.
    FILE_HEADER = /^FILE:[ \t]*(\S.*?)[ \t]*$/

    # Fence di apertura immediatamente dopo l'header (```ruby, ```rb, ``` …).
    OPENING_FENCE = /\A```[\w+-]*[ \t]*\z/

    CLOSING_FENCE = /\A```[ \t]*\z/

    PR_BODY_BLOCK = /^PR_BODY_START\s*\n(.*?)\nPR_BODY_END/m

    # Un path plausibile: nessuno spazio, nessun backtick.
    PLAUSIBLE_PATH = %r{\A[\w./@+-]+\z}

    def self.parse(content)
      lines  = content.to_s.lines
      blocks = []
      i      = 0

      while i < lines.size
        header = lines[i][FILE_HEADER, 1]
        unless header
          i += 1
          next
        end

        path = header.strip.delete_suffix(":")
        unless path.match?(PLAUSIBLE_PATH)
          i += 1
          next
        end

        i += 1
        body, i = if lines[i].to_s.chomp.match?(OPENING_FENCE)
                    read_fenced(lines, i + 1)
        else
                    read_plain(lines, i)
        end

        blocks << { path: path, content: body }
      end

      blocks
    end

    def self.parse_pr_body(content)
      match = content.to_s.match(PR_BODY_BLOCK)
      match&.captures&.first&.strip
    end

    # Legge fino alla fence di chiusura. Se manca (risposta troncata) si ferma al prossimo
    # marker: rilevare il troncamento è responsabilità di MistralClient, non del parser.
    def self.read_fenced(lines, start)
      body = []
      i    = start

      while i < lines.size
        line = lines[i]
        break if line.chomp.match?(CLOSING_FENCE)
        break if line.match?(FILE_HEADER) || line.start_with?("PR_BODY_START")

        body << line
        i += 1
      end

      i += 1 if i < lines.size && lines[i].to_s.chomp.match?(CLOSING_FENCE)
      [body.join, i]
    end
    private_class_method :read_fenced

    def self.read_plain(lines, start)
      body = []
      i    = start

      while i < lines.size
        line = lines[i]
        break if line.match?(FILE_HEADER) || line.start_with?("PR_BODY_START")

        body << line
        i += 1
      end

      [body.join.rstrip, i]
    end
    private_class_method :read_plain
  end
end
