# frozen_string_literal: true
# Costruisce il prompt per il fix CI dato l'output dei test falliti.
# Estratto da ci_fix_flow.rb — singola responsabilità.
#
# Uso:
#   Calvin::FixPromptBuilder.build(test_output:, github:) → String

module Calvin
  module FixPromptBuilder
    def self.build(test_output:, github:)
      error_blocks = extract_error_blocks(test_output)
      source_files = extract_source_files(test_output)
      Calvin::LOG.info "FixPromptBuilder: source files rilevati: #{source_files.join(', ')}"

      file_contents = source_files.filter_map do |path|
        content = github.get_file_content(path)
        next unless content
        Calvin::LOG.info "FixPromptBuilder: injecting #{path}"
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

    # Estrae i blocchi Failure/Error dallo stacktrace Minitest.
    def self.extract_error_blocks(output)
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
    private_class_method :extract_error_blocks

    # Estrae path dei file sorgente dallo stacktrace (esclude test/).
    def self.extract_source_files(output)
      output
        .scan(%r{(app/[\w/]+\.rb):\d+})
        .flatten
        .uniq
        .reject { |p| p.include?("test/") }
    end
    private_class_method :extract_source_files
  end
end
