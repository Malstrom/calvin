# frozen_string_literal: true
# Flusso di implementazione Calvin (calvin-direct):
#   1. Inietta contenuto dei file `modified` nel prompt
#   2. Aggiunge RESPONSE FORMAT (hardcodato — contratto tecnico del parser)
#   3. Appende convenzioni progetto da backend/api/.calvin/prompt in synca (se esiste)
#   4. Chiama Codestral (singola chiamata)
#   5. Posta il commento sull'issue (piano + token report)
#   6. Parsea i FILE: blocks dalla risposta
#   7. Rubocop autocorrect sui file .rb
#   8. Commit atomico + apre PR con token report nel body (via CommitAndPr)
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

    FILE_LIST_PATTERN   = /^-\s+(.+?)\s+[—-]+\s+(new|modified)$/i
    PROJECT_PROMPT_PATH = "backend/api/.calvin/prompt"

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

      pr_url = commit_and_open_pr(files, issue: @issue, usage: usage)
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
        Calvin::LOG.warn "project prompt non trovato: #{PROJECT_PROMPT_PATH} — continuo senza convenzioni aggiuntive"
        nil
      end
    end

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

      extra = project_prompt
      project_conventions = extra ? "\n\n#{extra}" : ""

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
        #{project_conventions}
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
