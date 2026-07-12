# frozen_string_literal: true
# Scrive il file di test per un singolo file sorgente.
#
# .call(source_path, github:, rag:, test_helper:, rules:, mistral:)
#   → Success({ path: String, content: String, usage: Hash })
#   | Failure({ step: :test_writer, error: String })
#
# .fix(test_path, test_content, error_output, source_path, github:, mistral:)
#   → Success({ path: String, content: String, usage: Hash })
#   | Failure({ step: :test_fix, error: String })
#
# source_path: path relativo al repo_root (es. "app/services/magic_link_service.rb")
# github:      Calvin::GitHubClient
# rag:         Calvin::SupabaseStore
# test_helper: String — contenuto di test/test_helper.rb (precaricato da TestFlow)
# rules:       String — rules RAG iniettate ultime (recency bias)
# mistral:     Calvin::MistralClient

require "dry/monads"

module Calvin
  module TestWriter
    include Dry::Monads[:result]
    extend self

    TESTABLE_DIRS = %w[app/services/ app/contracts/ app/jobs/].freeze

    # Deriva il path del test file dal path del sorgente.
    # es. app/services/magic_link_service.rb → test/services/magic_link_service_test.rb
    # Ritorna nil se il sorgente non è testabile.
    def test_path_for(source_path)
      TESTABLE_DIRS.each do |dir|
        next unless source_path.start_with?(dir)

        type = dir.split("/").last
        name = File.basename(source_path, ".rb")
        return "test/#{type}/#{name}_test.rb"
      end
      nil
    end

    def call(source_path, github:, rag:, test_helper:, rules:, mistral:)
      test_path    = test_path_for(source_path)
      return Failure(step: :test_writer, error: "not a testable path: #{source_path}") unless test_path

      source       = github.get_file_content(source_path).to_s
      current_test = github.get_file_content(test_path).to_s
      fixtures     = resolve_fixtures(source, source_path, rag)
      example      = fetch_example(source_path, test_path, github)
      system_prompt = load_system_prompt

      user_message = build_message(
        source_path:  source_path,
        source:       source,
        test_path:    test_path,
        current_test: current_test,
        fixtures:     fixtures,
        test_helper:  test_helper,
        example:      example,
        rules:        rules
      )

      response = mistral.complete_messages(
        [
          { role: "system", content: system_prompt },
          { role: "user",   content: user_message }
        ],
        temperature: temperature
      )

      result = parse_response(response[:content], test_path)
      Success(result.merge(usage: response[:usage]))
    rescue => e
      Failure(step: :test_writer, error: e.message)
    end

    def fix(test_path, test_content, error_output, source_path, github:, mistral:)
      source = github.get_file_content(source_path).to_s

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

      response = mistral.complete_messages(
        [{ role: "user", content: user_message }],
        temperature: temperature
      )

      result = parse_response(response[:content], test_path)
      Success(result.merge(usage: response[:usage]))
    rescue => e
      Failure(step: :test_fix, error: e.message)
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

    # Estrae costanti CamelCase dal sorgente, le converte in fixture paths
    # e fa un fetch deterministico dal RAG (nessun similarity search).
    def resolve_fixtures(source, source_path, rag)
      constants = source.scan(/\b[A-Z][A-Za-z]+\b/).uniq
      fixture_paths = constants.map do |const|
        snake  = const.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                      .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                      .downcase
        "fixture/#{snake}s.yml"
      end.uniq

      chunks = rag.fetch_by_source_paths(
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
    def fetch_example(source_path, test_path, github)
      type     = source_path.split("/")[1]           # "services", "contracts", "jobs"
      type_dir = "test/#{type}"
      candidates = github.list_directory(type_dir)
      example_name = candidates.find { |f| f.end_with?("_test.rb") && "#{type_dir}/#{f}" != test_path }
      return "(none)" unless example_name

      github.get_file_content("#{type_dir}/#{example_name}").to_s
    rescue
      "(none)"
    end

    def build_message(source_path:, source:, test_path:, current_test:, fixtures:,
                      test_helper:, example:, rules:)
      <<~MSG
        SOURCE: #{source_path}
        #{source}

        TEST FILE: #{test_path}
        #{current_test.empty? ? '(empty — create from scratch)' : current_test}

        FIXTURES:
        #{fixtures}

        TEST_HELPER:
        #{test_helper}

        EXAMPLE:
        #{example}

        RULES:
        #{rules}
      MSG
    end

    def parse_response(content, test_path)
      files = Calvin::FileParser.parse(content.to_s)
      file  = files.first

      if file
        { path: file[:path], content: file[:content] }
      else
        Calvin::LOG.warn "TestWriter: no FILE block found, using raw response"
        { path: test_path, content: content.to_s.strip }
      end
    end
  end
end
