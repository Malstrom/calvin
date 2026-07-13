# frozen_string_literal: true
# TestFlow — scrive i file di test per tutti i path testabili di un file_plan.
#
# .call(source_paths, github:, mistral:)
#   => Success({ tests_written: Integer, writer_errors: Integer, tests_skipped: Integer, written: [...] })
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
      all       = Array(source_paths)
      testable  = all.select { |p| TestWriter.test_path_for(p) }
      skipped   = all.size - testable.size

      if testable.empty?
        Calvin::LOG.info "TestFlow: nessun path testabile trovato — skip"
        return Success(tests_written: 0, writer_errors: 0, tests_skipped: skipped, written: [])
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

      errors = testable.size - written.size

      Success(
        tests_written: written.size,
        writer_errors: errors,
        tests_skipped: skipped,
        written:       written
      )
    rescue => e
      Failure(step: :test_flow, error: e.message)
    end
  end
end
