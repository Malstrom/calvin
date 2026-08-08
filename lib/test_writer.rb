# frozen_string_literal: true
# Scrive il file di test per un singolo file sorgente.
#
# .call(source_path, github:, mistral:)
#   → Success({ path: String, content: String, usage: Hash, retrieval: RetrievalResult })
#   | Failure({ step: :test_writer, error: String })
#
# .fix(test_path, test_content, error_output, source_path, github:, mistral:)
#   → Success({ path: String, content: String, usage: Hash })
#   | Failure({ step: :test_fix, error: String })
#
# .test_path_for(source_path) → String | nil
#
# source_path: path relativo al repo_root (es. "app/services/magic_link_service.rb")
# github:      Calvin::GitHubClient
# mistral:     Calvin::MistralClient
#
# Il contesto RAG (fixtures, test_helper, rules) viene recuperato interamente
# via ContextRetriever.call_for_test(source_path) — similarity search su
# calvin_context_search con source_types=['fixture','test_helper','rule'].
# Nessun fetch deterministico per path, nessuna regex CamelCase.

require "dry/monads"
require_relative "context_retriever"

module Calvin
  module TestWriter
    include Dry::Monads[:result]
    extend self

    # Deriva il path del test file dal path del sorgente.
    # es. app/services/magic_link_service.rb → test/services/magic_link_service_test.rb
    # Ritorna nil se il sorgente non è testabile per questo progetto.
    #
    # La mappa la definisce il repo target in `.calvin/project.yml` (`test.path_map`), non
    # Calvin: prima era la costante TESTABLE_DIRS = [app/services/, app/contracts/, app/jobs/],
    # cioè i layer di synca, che su un altro progetto avrebbe dichiarato non testabile tutto.
    def test_path_for(source_path, profile: nil)
      (profile || Calvin::ProjectProfile.default).test_path_for(source_path)
    end

    def call(source_path, github:, mistral:)
      test_path = test_path_for(source_path)
      return Failure(step: :test_writer, error: "not a testable path: #{source_path}") unless test_path

      source        = github.get_file_content(source_path).to_s
      current_test  = github.get_file_content(test_path).to_s
      retrieval     = ContextRetriever.call_for_test(source_path)
      example       = fetch_example(source_path, test_path, github)
      system_prompt = load_system_prompt

      user_message = build_message(
        source_path:  source_path,
        source:       source,
        test_path:    test_path,
        current_test: current_test,
        context:      retrieval.rules || "(none)",
        example:      example
      )

      response = mistral.complete_messages(
        [
          { role: "system", content: system_prompt },
          { role: "user",   content: user_message }
        ],
        temperature: temperature
      )

      result = parse_response(response[:content], test_path)
      # Ritorna anche il retrieval per il commento PR
      Success(result.merge(usage: response[:usage], retrieval: retrieval))
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

    # Cerca un file di test esistente dello stesso tipo come esempio di pattern.
    # Esclude il file che stiamo scrivendo.
    def fetch_example(source_path, test_path, github)
      type       = source_path.split("/")[1]
      type_dir   = "test/#{type}"
      candidates = github.list_directory(type_dir)
      example_name = candidates.find { |f| f.end_with?("_test.rb") && "#{type_dir}/#{f}" != test_path }
      return "(none)" unless example_name

      github.get_file_content("#{type_dir}/#{example_name}").to_s
    rescue
      "(none)"
    end

    # context: output di retrieval.rules — mix di fixture, test_helper e rules
    # ordinati per similarity, formattati da ContextRetriever#format_rules.
    def build_message(source_path:, source:, test_path:, current_test:, context:, example:)
      <<~MSG
        SOURCE: #{source_path}
        #{source}

        TEST FILE: #{test_path}
        #{current_test.empty? ? '(empty — create from scratch)' : current_test}

        CONTEXT (fixtures, test_helper, rules):
        #{context}

        EXAMPLE:
        #{example}
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
