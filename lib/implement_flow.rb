# frozen_string_literal: true
# Flusso di implementazione Calvin (calvin-direct):
#   1. Inietta contenuto dei file `modified` nel prompt
#   2. Aggiunge le istruzioni sul formato FILE: + convenzioni test
#   3. Chiama Codestral (singola chiamata)
#   4. Posta il commento sull'issue (piano + token report)
#   5. Parsea i FILE: blocks dalla risposta
#   6. Rubocop autocorrect sui file .rb
#   7. Commit atomico + apre PR  (via CommitAndPr)
#
# .run → Success(pr_url) | Failure(msg)

require "dry/monads"
require_relative "file_parser"
require_relative "commit_and_pr"
require_relative "rubocop_autocorrect"

module Calvin
  class ImplementFlow
    include Dry::Monads[:result]
    include CommitAndPr
    include RubocopAutocorrect

    FILE_LIST_PATTERN = /^-\s+(.+?)\s+[—-]+\s+(new|modified)$/i

    TEST_CONVENTIONS = <<~CONVENTIONS.freeze
      ## TEST CONVENTIONS (MANDATORY)

      For every new .rb file that is NOT a test, you MUST produce the corresponding test file.
      Test files are required output, not optional.

      FIXTURES available (always use fixtures, never ActiveRecord.create in setup):
      - users(:alice), users(:bob), users(:charlie)
      - preference_profiles(:alice_prefs), preference_profiles(:bob_prefs)
      - health_summaries, profiles, spark_sessions, matches

      BASE CLASSES:
      - ActiveSupport::TestCase    — for model, service, contract tests
      - ApiTestCase                — for controller/integration tests

      HELPERS available in ApiTestCase:
      - auth_headers(user)                        — returns Authorization Bearer + Content-Type
      - post_json(path, params:, headers:)         — POST with JSON body
      - put_json(path, params:, headers:)          — PUT with JSON body
      - json                                       — response.body parsed with symbolize_names: true

      HELPERS available in ActiveSupport::TestCase:
      - assert_pattern { result => Success(value) }     — for Dry::Monads results
      - assert_pattern { result => Failure[:code, _] }
      - include Dry::Monads[:result] if asserting Success/Failure directly

      MINIMUM COVERAGE:
      - At least one happy path + one error/edge path per public method
      - Controllers: always test 401 (no token) + 422 (invalid params) + 200 (happy path)
      - Do NOT re-test what is already covered in the corresponding contract test

      SERVICE TEST STRUCTURE:
        class FooServiceTest < ActiveSupport::TestCase
          include Dry::Monads[:result]
          setup { @user = users(:alice) }
          test "returns Success on valid attrs" do ... end
          test "returns Failure on invalid attrs" do ... end
        end

      CONTROLLER TEST STRUCTURE:
        class Api::V1::Signals::FooControllerTest < ApiTestCase
          setup do
            @user = users(:alice)
            @headers = auth_headers(@user)
            @valid_params = { ... }
          end
          test "POST /api/v1/signals/foo returns 200" do ... end
          test "POST without token returns 401" do ... end
          test "POST with invalid params returns 422" do ... end
        end
    CONVENTIONS

    def initialize(github, issue, prompt)
      @github = github
      @issue  = issue
      @prompt = prompt
    end

    def run
      enriched = inject_existing_files(@prompt)
      result   = MistralClient.new.complete(enriched)
      content  = result[:content]
      usage    = result[:usage]

      post_comment(content, usage)

      files = FileParser.parse(content)
      Calvin::LOG.info "parsed #{files.size} file(s) from Codestral response"
      return Failure("No FILE: blocks found in Codestral response") if files.empty?

      files = autocorrect_files(files)

      pr_url = commit_and_open_pr(files, issue: @issue)
      Calvin::LOG.info "##{@issue.number} done — PR: #{pr_url}"
      Success(pr_url)
    rescue StandardError => e
      Failure("ImplementFlow error: #{e.message}")
    end

    private

    def inject_existing_files(prompt)
      modified_paths = prompt.scan(FILE_LIST_PATTERN).filter_map do |path, status|
        path.strip if status.downcase == "modified"
      end

      injected = modified_paths.filter_map do |path|
        content = @github.get_file_content(path)
        next unless content
        Calvin::LOG.info "injecting existing file: #{path}"
        "---\n#{path}\n#{content}\n---"
      end.join("\n\n")

      file_context = injected.empty? ? "" : "\n\n## EXISTING FILE CONTENTS\n\n#{injected}"

      <<~PROMPT
        #{prompt}#{file_context}

        ## RESPONSE FORMAT

        For every file listed above, provide the complete file content using this exact format:

        FILE: path/to/file.rb
        ```ruby
        # complete file content here
        ```

        Rules:
        - Output one FILE: block per file, in the same order as the list above.
        - For new files: provide full content from scratch.
        - For modified files: provide the complete updated file (not a diff).
        - Use the correct language identifier in the code fence (ruby, yml, sql, etc).
        - Do not add any text between FILE: blocks.

        #{TEST_CONVENTIONS}
      PROMPT
    end

    def post_comment(content, usage)
      token_report = if usage
        pt = usage["prompt_tokens"] || 0
        ct = usage["completion_tokens"] || 0
        tt = usage["total_tokens"] || 0
        "| prompt | completion | total |\n|--------|------------|-------|\n| #{pt} | #{ct} | #{tt} |"
      else
        "_token data unavailable_"
      end

      @github.post_status(@issue, <<~MD)
        <!-- calvin-status -->
        ## \u{1F4E4} Calvin — Implementation Plan

        #{content}

        ---
        ### \u{1F4CA} Token usage
        #{token_report}
      MD
    end
  end
end
