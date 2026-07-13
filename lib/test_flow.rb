# frozen_string_literal: true
# TestFlow — scrive i file di test per tutti i path testabili di un file_plan.
#
# .call(source_paths, branch:, github:, mistral:)
#   => Success({ tests_written: Integer, writer_errors: Integer, tests_skipped: Integer,
#                written: [...], usage_total: Hash, retrievals: [...] })
#    | Failure({ step: :test_flow, error: String })
#
# source_paths: Array di path (output del file_plan di implement)
# branch:       nome del branch su cui committare i test (da FlowResult#branch)
# github:       Calvin::GitHubClient
# mistral:      Calvin::MistralClient
#
# Per ogni path testabile:
#   1. TestWriter.call  — genera il contenuto via LLM + ContextRetriever
# Tutti i file generati vengono committati in un unico commit atomico via
# github.commit_files_atomically.
#
# I path non testabili (fuori da TESTABLE_DIRS) vengono silenziosamente ignorati.

require "dry/monads"
require_relative "test_writer"

module Calvin
  module TestFlow
    include Dry::Monads[:result]
    extend self

    def call(source_paths, branch:, github:, mistral:)
      all      = Array(source_paths)
      testable = all.select { |p| TestWriter.test_path_for(p) }
      skipped  = all.size - testable.size

      if testable.empty?
        Calvin::LOG.info "TestFlow: nessun path testabile trovato — skip"
        return Success(tests_written: 0, writer_errors: 0, tests_skipped: skipped,
                       written: [], usage_total: nil, retrievals: [])
      end

      Calvin::LOG.info "TestFlow: #{testable.size} path testabili: #{testable.inspect}"

      writer_errors   = 0
      files_to_commit = []
      retrievals      = []
      usages          = []

      testable.each do |source_path|
        result = TestWriter.call(source_path, github: github, mistral: mistral)

        if result.failure?
          Calvin::LOG.warn "TestFlow: TestWriter fallito per #{source_path} — #{result.failure[:error]}"
          writer_errors += 1
          next
        end

        test = result.value!
        Calvin::LOG.info "TestFlow: generato #{test[:path]} (usage=#{test[:usage].inspect})"
        files_to_commit << { path: test[:path], content: test[:content] }
        usages     << test[:usage]     if test[:usage]
        retrievals << test[:retrieval] if test[:retrieval]
      end

      if files_to_commit.any?
        begin
          github.commit_files_atomically(
            files_to_commit,
            message: "test: add generated test files [calvin]",
            branch:  branch
          )
          files_to_commit.each do |f|
            Calvin::LOG.info "TestFlow: scritto #{f[:path]}"
          end
        rescue => e
          Calvin::LOG.error "TestFlow: commit_files_atomically fallito — #{e.message}"
          writer_errors += files_to_commit.size
          files_to_commit = []
        end
      end

      # Aggrega usage di tutti i test scritti
      usage_total = if usages.any?
        {
          "prompt_tokens"     => usages.sum { |u| u["prompt_tokens"].to_i },
          "completion_tokens" => usages.sum { |u| u["completion_tokens"].to_i },
          "cached_tokens"     => usages.sum { |u| u["cached_tokens"].to_i }
        }
      end

      Success(
        tests_written: files_to_commit.size,
        writer_errors: writer_errors,
        tests_skipped: skipped,
        written:       files_to_commit,
        usage_total:   usage_total,
        retrievals:    retrievals
      )
    rescue => e
      Failure(step: :test_flow, error: e.message)
    end
  end
end
