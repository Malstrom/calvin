# frozen_string_literal: true
# Calvin::TestGenerator — scrive test per i file sorgente prodotti in un run.
#
# Sostituisce TestWriter/TestFlow. Due differenze deliberate rispetto al vecchio
# meccanismo:
#
#   1. Fixtures e test_helper.rb sono path noti: si leggono con un fetch diretto (via
#      RepoReader, quindi dal clone locale quando disponibile) invece che con una
#      similarity search su Supabase. Non c'è nulla da "trovare per somiglianza" in un
#      file il cui path è già scritto in config/calvin.yml.
#   2. Nessun meccanismo di correzione dedicato (il vecchio TestWriter.fix). I test
#      generati qui vengono aggiunti al batch di file PRIMA di Validator: se
#      `bin/rails test` li boccia, rientrano nella stessa ladder Validator+RepairLoop
#      di qualunque altro file — già gate-agnostic, non serve duplicarla.
#
# Si inserisce fra parse_files e validate_and_repair (vedi ExploreFlow#generate_tests):
# i test generati entrano nel batch prima che rubocop/i gate strutturali girino, così
# codice e test passano per lo stesso giro di lint invece di due passaggi separati.
#
# .call(files:, reader:, mistral:) → { files: [{path:, content:}], skipped: Integer }
#
# files:   i file sorgente appena prodotti dall'implement (output di parse_files)
# reader:  Calvin::RepoReader — legge fixtures/test_helper/esempio, con fallback API
# mistral: client iniettato (lo stesso del resto del flow)
#
# Attivo solo se test_generation.enabled è true nella config effettiva (Calvin.config) —
# opt-in per progetto via .calvin/calvin.yml. Mai bloccante: un errore di generazione per
# un singolo file viene loggato e saltato, non fa fallire il run.

require_relative "syntax_check"
require_relative "file_parser"

module Calvin
  module TestGenerator
    extend self

    DEFAULT_TESTABLE_DIRS = %w[app/services/ app/contracts/ app/jobs/].freeze

    def call(files:, reader:, mistral:)
      config = Calvin.config[:test_generation] || {}
      return { files: [], skipped: 0 } unless config[:enabled]

      candidates = testable_candidates(files, config)
      return { files: [], skipped: 0 } if candidates.empty?

      max_files = config[:max_files] || 3
      selected  = candidates.first(max_files)
      over_cap  = candidates.size - selected.size
      Calvin::LOG.info "TestGenerator: #{over_cap} file(s) oltre il tetto (#{max_files}) — non generati" if over_cap.positive?

      generated = selected.filter_map { |source, test_path| generate(source, test_path, reader, mistral) }
      { files: generated, skipped: over_cap }
    end

    private

    # [[source_file, test_path], ...] — solo i file testabili la cui sintassi è già
    # valida: un test per codice che non parserebbe verrebbe comunque scartato dal gate
    # syntax, quindi non vale la chiamata al modello.
    def testable_candidates(files, config)
      dirs = Array(config[:testable_dirs])
      dirs = DEFAULT_TESTABLE_DIRS if dirs.empty?

      files.filter_map do |f|
        path = f[:path].to_s
        next if path.start_with?("test/")

        test_path = test_path_for(path, dirs)
        next unless test_path

        unless Calvin::SyntaxCheck.ok?(f[:content])
          Calvin::LOG.info "TestGenerator: #{path} non passa il pre-check di sintassi — salto (andrà a repair sul codice)"
          next
        end

        [f, test_path]
      end
    end

    # app/services/magic_link_service.rb → test/services/magic_link_service_test.rb
    def test_path_for(source_path, dirs)
      dirs.each do |dir|
        next unless source_path.start_with?(dir)

        type = dir.split("/").last
        name = File.basename(source_path, ".rb")
        return "test/#{type}/#{name}_test.rb"
      end
      nil
    end

    def generate(source_file, test_path, reader, mistral)
      response = mistral.complete_messages(
        [
          { role: "system", content: system_prompt },
          { role: "user",   content: build_message(source_file, test_path, reader) }
        ],
        temperature: temperature
      )

      result = parse_response(response[:content], test_path)
      Calvin::LOG.info "TestGenerator: generato #{result[:path]}" if result
      result
    rescue => e
      Calvin::LOG.warn "TestGenerator: generazione fallita per #{test_path} — #{e.class}: #{e.message}"
      nil
    end

    def build_message(source_file, test_path, reader)
      source_path  = source_file[:path]
      current_test = reader.get_file_content(test_path)

      <<~MSG
        SOURCE: #{source_path}
        #{source_file[:content]}

        TEST FILE: #{test_path}
        #{current_test.to_s.empty? ? '(empty — create from scratch)' : current_test}

        CONTEXT (fixtures, test_helper):
        #{fixtures_and_helper(reader)}

        EXAMPLE:
        #{fetch_example(source_path, test_path, reader)}
      MSG
    end

    # Path noti — fetch diretto, nessun embedding.
    def fixtures_and_helper(reader)
      fixtures_dir = Calvin.config.dig(:project, :fixtures_dir) || "test/fixtures"
      helper_path  = Calvin.config.dig(:project, :test_helper_path) || "test/test_helper.rb"

      parts  = []
      helper = reader.get_file_content(helper_path)
      parts << "### test_helper.rb\n#{helper}" if helper

      reader.list_directory(fixtures_dir).select { |n| n.end_with?(".yml") }.each do |name|
        content = reader.get_file_content("#{fixtures_dir}/#{name}")
        parts << "### #{name}\n#{content}" if content
      end

      parts.any? ? parts.join("\n\n") : "(none)"
    end

    # Un test esistente dello stesso layer come pattern — esclude il file che si sta
    # generando.
    def fetch_example(source_path, test_path, reader)
      type       = source_path.split("/")[1]
      type_dir   = "test/#{type}"
      candidates = reader.list_directory(type_dir)
      example    = candidates.find { |f| f.end_with?("_test.rb") && "#{type_dir}/#{f}" != test_path }
      return "(none)" unless example

      reader.get_file_content("#{type_dir}/#{example}") || "(none)"
    rescue
      "(none)"
    end

    def system_prompt
      @system_prompt ||= File.read(File.join(__dir__, "../config/prompts/rails/test_system.md"))
    end

    def temperature
      Calvin.config.dig(:sampling, :temperature, :test) || 0.0
    end

    def parse_response(content, test_path)
      file = Calvin::FileParser.parse(content.to_s).first
      return { path: file[:path], content: file[:content] } if file

      Calvin::LOG.warn "TestGenerator: nessun FILE block nella risposta per #{test_path} — scartato"
      nil
    end
  end
end
