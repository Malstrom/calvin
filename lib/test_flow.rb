# frozen_string_literal: true
# TestFlow — scrive i file di test per tutti i path testabili di un file_plan.
#
# .call(source_paths, github:, mistral:)
#   => Success({ tests_written: [{ path:, content:, usage: }] })
#    | Failure({ step: :test_flow, error: String })
#
# source_paths: Array di path (output del file_plan di implement)
# github:       Calvin::GitHubClient
# mistral:      Calvin::MistralClient
#
# Per ogni path testabile:
#   1. TestWriter.call  — genera il contenuto via LLM + ContextRetriever
#   2. github.write_file — committa il file sul branch
#
# I path non testabili (fuori da TESTABLE_DIRS) vengono silenziosamente ignorati.

require "dry/monads"
require_relative "test_writer"

module Calvin
  module TestFlow
    include Dry::Monads[:result]
    extend self

    def call(source_paths, github:, mistral:)
      testable = Array(source_paths).select { |p| TestWriter.test_path_for(p) }

      if testable.empty?
        Calvin::LOG.info "TestFlow: nessun path testabile trovato — skip"
        return Success(tests_written: [])
      end

      Calvin::LOG.info "TestFlow: #{testable.size} path testabili: #{testable.inspect}"

      written = testable.filter_map do |source_path|
        result = TestWriter.call(source_path, github: github, mistral: mistral)

        if result.failure?
          Calvin::LOG.warn "TestFlow: TestWriter fallito per #{source_path} — #{result.failure[:error]}"
          next
        end

        test = result.value!
        github.write_file(test[:path], test[:content])
        Calvin::LOG.info "TestFlow: scritto #{test[:path]} (usage=#{test[:usage].inspect})"
        test
      end

      Success(tests_written: written)
    rescue => e
      Failure(step: :test_flow, error: e.message)
    end
  end
end
