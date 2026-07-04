# frozen_string_literal: true
# Flusso di implementazione Calvin (calvin-direct):
#   1. Inietta contenuto dei file `modified` nel prompt
#   2. Aggiunge le istruzioni sul formato FILE:
#   3. Chiama Codestral (singola chiamata)
#   4. Posta il commento sull'issue (piano + token report)
#   5. Parsea i FILE: blocks dalla risposta
#   6. Commit atomico + apre PR  (via CommitAndPr)
#
# .run → Success(pr_url) | Failure(msg)

require "dry/monads"
require_relative "file_parser"
require_relative "commit_and_pr"

module Calvin
  class ImplementFlow
    include Dry::Monads[:result]
    include CommitAndPr

    FILE_LIST_PATTERN = /^-\s+(.+?)\s+[—-]+\s+(new|modified)$/i

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
        ## \u{1F4E4} Calvin \u2014 Implementation Plan

        #{content}

        ---
        ### \u{1F4CA} Token usage
        #{token_report}
      MD
    end
  end
end
