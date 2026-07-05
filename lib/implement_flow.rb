# frozen_string_literal: true
# Flusso di implementazione Calvin (calvin-direct):
#   1. Inietta contenuto dei file `modified` nel prompt
#   2. Se l'issue genera test, inietta:
#        - .calvin/testing.yml     (convenzioni test del progetto)
#        - test/test_helper.rb     (classi base e helper reali)
#        - test/support/*.rb       (se esiste)
#        - un controller test di esempio (me_controller_test.rb)
#        - le fixture dei model toccati dall'issue
#   3. Aggiunge RESPONSE FORMAT (hardcodato — contratto tecnico del parser)
#   4. Appende convenzioni progetto da .calvin/prompt (se esiste)
#   5. Chiama Codestral (singola chiamata)
#   6. Posta il commento sull'issue (piano + token report)
#   7. Parsea i FILE: blocks e il PR_BODY block dalla risposta
#   8. Commit atomico + apre PR con description e token report nel body (via CommitAndPr)
#
# .run        → Success(pr_url) | Failure(msg)
# .last_usage → Hash | nil  (disponibile dopo .run, per RunReporter)

require "dry/monads"
require_relative "file_parser"
require_relative "commit_and_pr"

module Calvin
  class ImplementFlow
    include Dry::Monads[:result]
    include CommitAndPr

    attr_reader :last_usage

    FILE_LIST_PATTERN    = /^-\s+(.+?)\s+[—-]+\s+(new|modified)$/i
    MODEL_PATH_PATTERN   = %r{app/models/([\w/]+)\.rb}
    PROJECT_PROMPT_PATH  = ".calvin/prompt"
    TESTING_YML_PATH     = ".calvin/testing.yml"
    CONTROLLER_TEST_EXAMPLE = "test/controllers/api/v1/me_controller_test.rb"

    def initialize(github, issue, prompt)
      @github     = github
      @issue      = issue
      @prompt     = prompt
      @last_usage = nil
    end

    def run
      enriched   = inject_existing_files(@prompt)
      result     = MistralClient.new.complete(enriched)
      content    = result[:content]
      @last_usage = result[:usage]

      post_comment(content, @last_usage)

      files = FileParser.parse(content)
      Calvin::LOG.info "parsed #{files.size} file(s) from Codestral response"
      return Failure("No FILE: blocks found in Codestral response") if files.empty?

      description = FileParser.parse_pr_body(content)
      Calvin::LOG.info(description ? "PR body extracted (#{description.bytesize} bytes)" : "PR body not found in response")

      pr_url = commit_and_open_pr(files, issue: @issue, usage: @last_usage, description: description)
      Calvin::LOG.info "##{@issue.number} done — PR: #{pr_url}"
      Success(pr_url)
    rescue StandardError => e
      Failure("ImplementFlow error: #{e.message}")
    end

    private

    def project_prompt
      content = @github.get_file_content(PROJECT_PROMPT_PATH)
      if content
        Calvin::LOG.info "project prompt trovato: #{PROJECT_PROMPT_PATH} (#{content.bytesize} bytes)"
        content
      else
        Calvin::LOG.warn "project prompt non trovato: #{PROJECT_PROMPT_PATH} — continuo senza"
        nil
      end
    end

    def inject_existing_files(prompt)
      all_paths = prompt.scan(FILE_LIST_PATTERN).map { |path, _| path.strip }

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
      test_context = needs_test_helpers?(prompt) ? inject_test_helpers(all_paths) : ""

      extra = project_prompt
      project_conventions = extra ? "\n\n#{extra}" : ""

      <<~PROMPT
        #{prompt}#{file_context}#{test_context}

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

        After all FILE: blocks, provide a pull request description in this exact format:

        PR_BODY_START
        ## What this does
        - <concise bullet describing what the implementation does>

        ## Decisions made
        - <decision taken and why — be specific, not generic>

        ## Alternatives rejected
        - <alternative approach> — <why it was not chosen>

        ## Risks
        - Product: <risk or "none">
        - Technical: <risk or "none">
        PR_BODY_END

        Rules for PR_BODY_START/PR_BODY_END:
        - Always include this block, even if some sections are short.
        - Be specific: reference actual class names, field names, or design decisions from the implementation.
        - Do not leave placeholder text like "<risk>" in the output.
        #{project_conventions}
      PROMPT
    end

    def needs_test_helpers?(prompt)
      prompt.match?(/test\//i) || prompt.match?(/\btest\b/i)
    end

    def inject_test_helpers(all_paths)
      blocks = []

      testing_yml = @github.get_file_content(TESTING_YML_PATH)
      if testing_yml
        Calvin::LOG.info "injecting #{TESTING_YML_PATH}"
        blocks << "---\n#{TESTING_YML_PATH}\n#{testing_yml}\n---"
      else
        Calvin::LOG.warn "#{TESTING_YML_PATH} non trovato"
      end

      helper = @github.get_file_content("test/test_helper.rb")
      if helper
        Calvin::LOG.info "injecting test/test_helper.rb"
        blocks << "---\ntest/test_helper.rb\n#{helper}\n---"
      end

      support_files = @github.list_directory("test/support")
      support_files.select { |name| name.end_with?(".rb") }.each do |name|
        path    = "test/support/#{name}"
        content = @github.get_file_content(path)
        next unless content
        Calvin::LOG.info "injecting #{path}"
        blocks << "---\n#{path}\n#{content}\n---"
      end

      if needs_controller_test?(all_paths)
        example = @github.get_file_content(CONTROLLER_TEST_EXAMPLE)
        if example
          Calvin::LOG.info "injecting controller test example: #{CONTROLLER_TEST_EXAMPLE}"
          blocks << "---\nEXAMPLE — copy this exact pattern for controller tests:\n#{CONTROLLER_TEST_EXAMPLE}\n#{example}\n---"
        end
      end

      fixture_blocks = inject_model_fixtures(all_paths)
      blocks.concat(fixture_blocks)

      return "" if blocks.empty?

      "\n\n## TEST CONTEXT (read carefully before writing any test)\n\n" + blocks.join("\n\n")
    end

    def needs_controller_test?(all_paths)
      all_paths.any? { |p| p.include?("test/controllers") }
    end

    def inject_model_fixtures(paths)
      paths.filter_map do |path|
        match = path.match(MODEL_PATH_PATTERN)
        next unless match

        model_name   = match[1]
        table_name   = model_name.gsub("/", "_") + "s"
        fixture_path = "test/fixtures/#{table_name}.yml"

        content = @github.get_file_content(fixture_path)
        unless content
          Calvin::LOG.warn "fixture non trovata: #{fixture_path}"
          next
        end

        Calvin::LOG.info "injecting fixture: #{fixture_path}"
        "---\n#{fixture_path}\n#{content}\n---"
      end
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
