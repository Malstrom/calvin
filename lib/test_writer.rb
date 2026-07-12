# frozen_string_literal: true
# Scrive il file di test per un singolo file sorgente.
#
# .call(source_path, github:, rag:, test_helper:, rules:, mistral:) → { path: String, content: String }
# .fix(test_path, test_content, error_output, source_path, github:, rag:, test_helper:, mistral:) → { path: String, content: String }
#
# source_path: path relativo al repo_root (es. "app/services/magic_link_service.rb")
# github:      Calvin::GitHubClient
# rag:         Calvin::SupabaseStore
# test_helper: String — contenuto di test/test_helper.rb (precaricato da TestFlow)
# rules:       String — rules RAG (iniettate ultime per recency bias)
# mistral:     Calvin::MistralClient

module Calvin
  class TestWriter
    TESTABLE_DIRS = %w[app/services/ app/contracts/ app/jobs/].freeze

    # Deriva il path del test file dalla path del sorgente.
    # es. app/services/magic_link_service.rb → test/services/magic_link_service_test.rb
    def self.test_path_for(source_path)
      TESTABLE_DIRS.each do |dir|
        next unless source_path.start_with?(dir)

        type    = dir.split("/").last          # "services", "contracts", "jobs"
        name    = File.basename(source_path, ".rb")
        return "test/#{type}/#{name}_test.rb"
      end
      nil
    end

    def self.call(source_path, github:, rag:, test_helper:, rules:, mistral:)
      new(github: github, rag: rag, test_helper: test_helper, rules: rules, mistral: mistral)
        .write(source_path)
    end

    def self.fix(test_path, test_content, error_output, source_path, github:, rag:, test_helper:, mistral:)
      new(github: github, rag: rag, test_helper: test_helper, rules: "", mistral: mistral)
        .fix(test_path, test_content, error_output, source_path)
    end

    def initialize(github:, rag:, test_helper:, rules:, mistral:)
      @github      = github
      @rag         = rag
      @test_helper = test_helper
      @rules       = rules
      @mistral     = mistral
    end

    def write(source_path)
      test_path    = self.class.test_path_for(source_path)
      source       = @github.get_file_content(source_path).to_s
      current_test = @github.get_file_content(test_path).to_s  # nil → ""
      fixtures     = resolve_fixtures(source, source_path)
      example      = fetch_example(source_path, test_path)
      system_prompt = load_system_prompt

      user_message = build_message(
        source_path:  source_path,
        source:       source,
        test_path:    test_path,
        current_test: current_test,
        fixtures:     fixtures,
        example:      example
      )

      response = @mistral.complete_messages(
        [
          { role: "system", content: system_prompt },
          { role: "user",   content: user_message }
        ],
        temperature: temperature
      )

      parse_response(response[:content], test_path)
    end

    def fix(test_path, test_content, error_output, source_path)
      source = @github.get_file_content(source_path).to_s

      user_message = <<~MSG
        The test file below failed. Fix it so all tests pass.
        Do not change the test intentions — only fix what is broken.

        SOURCE: #{source_path}
        #{source}

        FAILING TEST FILE: #{test_path}
        #{test_content}

        TEST OUTPUT:
        #{error_output}
      MSG

      response = @mistral.complete_messages(
        [{ role: "user", content: user_message }],
        temperature: temperature
      )

      parse_response(response[:content], test_path)
    end

    private

    def load_system_prompt
      path = File.join(__dir__, "../config/prompts/rails/test_system.md")
      File.read(path)
    end

    def temperature
      Calvin::CONFIG.dig(:sampling, :temperature, :test) ||
        Calvin::CONFIG.dig(:sampling, :temperature, "test") ||
        0.0
    end

    # Estrae nomi di modelli Rails dal sorgente (costanti CamelCase) e carica
    # le fixtures corrispondenti dal RAG via fetch_by_source_paths deterministico.
    def resolve_fixtures(source, source_path)
      constants = source.scan(/\b[A-Z][A-Za-z]+\b/).uniq
      fixture_paths = constants.map do |const|
        snake = const.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                     .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                     .downcase
        plural = "#{snake}s"  # plurale semplice — copre 95% dei casi Rails
        "fixture/#{plural}.yml"
      end.uniq

      chunks = @rag.fetch_by_source_paths(
        repo:         Calvin::REPO,
        source_paths: fixture_paths
      )

      return "(none)" if chunks.empty?

      chunks.map { |c| "### #{c[:source_path]}\n#{c[:content]}" }.join("\n\n")
    rescue => e
      Calvin::LOG.warn "TestWriter: fixture fetch failed for #{source_path}: #{e.message}"
      "(none)"
    end

    # Cerca un file di test esistente dello stesso tipo come esempio di pattern.
    # Esclude il file che stiamo scrivendo.
    def fetch_example(source_path, test_path)
      type_dir = "test/#{source_path.split('/')[1]}/"  # es. "test/services/"
      candidates = @github.list_directory(type_dir.chomp("/"))
      example_name = candidates.find { |f| f.end_with?("_test.rb") && "#{type_dir}#{f}" != test_path }
      return "(none)" unless example_name

      @github.get_file_content("#{type_dir}#{example_name}").to_s
    rescue
      "(none)"
    end

    def build_message(source_path:, source:, test_path:, current_test:, fixtures:, example:)
      <<~MSG
        SOURCE: #{source_path}
        #{source}

        TEST FILE: #{test_path}
        #{current_test.empty? ? '(empty — create from scratch)' : current_test}

        FIXTURES:
        #{fixtures}

        TEST_HELPER:
        #{@test_helper}

        EXAMPLE:
        #{example}

        RULES:
        #{@rules}
      MSG
    end

    def parse_response(content, test_path)
      files = Calvin::FileParser.parse(content.to_s)
      file  = files.first

      if file
        { path: file[:path], content: file[:content] }
      else
        # fallback: tutta la risposta come contenuto, path derivato
        Calvin::LOG.warn "TestWriter: no FILE block found, using raw response"
        { path: test_path, content: content.to_s.strip }
      end
    end
  end
end
