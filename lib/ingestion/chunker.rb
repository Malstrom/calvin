# frozen_string_literal: true
# Chunker — split Markdown in chunk per heading H2/H3.
#
# Ingestion::Chunker.split(markdown, source_path_prefix: "docs/features/signals-v1.md")
# → [{ source_type: "doc", source_path: "docs/.../signals-v1.md#nome-sezione", content: String }, ...]
#
# Regole:
# - Split su ogni riga che inizia con ## o ###
# - Il titolo è incluso nel chunk come prima riga
# - Chunk vuoti (solo heading, nessun testo) vengono saltati
# - Chunk > MAX_CHARS vengono ulteriormente splittati per paragrafo (riga vuota)
# - source_path: "path/al/file.md#slug-heading" (slug: lowercase, spazi → trattini)

module Ingestion
  class Chunker
    MAX_CHARS = 2000

    # Determina source_type dal path
    def self.source_type_for(path)
      path.include?("conventions") ? "convention" : "doc"
    end

    def self.split(markdown, source_path_prefix:)
      source_type = source_type_for(source_path_prefix)
      sections    = split_by_headings(markdown)
      chunks      = []

      sections.each do |heading, body|
        next if body.strip.empty?

        slug    = slugify(heading)
        sp      = slug.empty? ? source_path_prefix : "#{source_path_prefix}##{slug}"
        content = heading.empty? ? body.strip : "#{heading}\n\n#{body.strip}"

        if content.length <= MAX_CHARS
          chunks << { source_type: source_type, source_path: sp, content: content }
        else
          # Split per paragrafo
          paragraphs = body.split(/\n{2,}/)
          paragraphs.each_with_index do |para, idx|
            next if para.strip.empty?

            sub_sp      = slug.empty? ? "#{source_path_prefix}#p#{idx}" : "#{source_path_prefix}##{slug}-p#{idx}"
            sub_content = idx.zero? && !heading.empty? ? "#{heading}\n\n#{para.strip}" : para.strip
            chunks << { source_type: source_type, source_path: sub_sp, content: sub_content }
          end
        end
      end

      chunks
    end

    # ── private ─────────────────────────────────────────────────────────────

    def self.split_by_headings(markdown)
      sections = []
      current_heading = ""
      current_body    = []

      markdown.each_line do |line|
        if line =~ /^##+ (.+)/
          sections << [current_heading, current_body.join] unless current_body.join.strip.empty? && current_heading.empty?
          current_heading = line.rstrip
          current_body    = []
        else
          current_body << line
        end
      end

      sections << [current_heading, current_body.join]
      sections
    end

    def self.slugify(heading)
      heading
        .gsub(/^##+ /, "")
        .downcase
        .gsub(/[^a-z0-9\s-]/, "")
        .gsub(/\s+/, "-")
        .strip
    end
  end
end
