# frozen_string_literal: true
# Flusso di implementazione Calvin:
#   1. Inietta contenuto dei file `modified` nel prompt
#   2. Chiama Codestral (una sola chiamata)
#   3. Posta il commento sull'issue (lista file + token report)
#   4. Parsea i FILE: blocks dalla risposta
#   5. Scrive i file sul branch → apre PR
#
# .run → Success(pr_url) | Failure(msg)

require "dry/monads"
require_relative "file_parser"

module Calvin
  class ImplementFlow
    include Dry::Monads[:result]

    # Marker nel prompt che indica la lista file da modificare/creare
    # Formato riga: `- path/to/file.rb — modified` o `— new`
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

      branch = write_files_to_branch(files)
      pr_url = open_pull_request(branch)

      Calvin::LOG.info "##{@issue.number} done — PR: #{pr_url}"
      Success(pr_url)
    rescue StandardError => e
      Failure("ImplementFlow error: #{e.message}")
    end

    private

    # Legge i file `modified` dal repo e li inietta nel prompt
    def inject_existing_files(prompt)
      modified_paths = extract_modified_paths(prompt)
      return prompt if modified_paths.empty?

      injected = modified_paths.filter_map do |path|
        content = @github.get_file_content(path)
        next unless content

        Calvin::LOG.info "injecting existing file: #{path}"
        "---\n#{path}\n#{content}\n---"
      end.join("\n\n")

      return prompt if injected.empty?

      <<~PROMPT
        #{prompt}

        ## EXISTING FILE CONTENTS (for modified files only)

        #{injected}

        ## RESPONSE FORMAT

        For each file in the list above, provide the complete file content using this exact format:

        FILE: path/to/file.rb
        ```ruby
        # complete file content here
        ```

        For new files: provide full content.
        For modified files: provide the complete updated file (not a diff).
      PROMPT
    end

    # Estrae i path dei file marcati come `modified` dalla lista nel prompt
    def extract_modified_paths(prompt)
      prompt.scan(FILE_LIST_PATTERN).filter_map do |path, status|
        path.strip if status.downcase == "modified"
      end
    end

    # Posta il commento sull'issue con lista file + token report
    def post_comment(content, usage)
      token_report = if usage
        pt = usage["prompt_tokens"] || 0
        ct = usage["completion_tokens"] || 0
        tt = usage["total_tokens"] || 0
        "| prompt | completion | total |\n|--------|------------|-------|\n| #{pt} | #{ct} | #{tt} |"
      else
        "_token data unavailable_"
      end

      comment = <<~MD
        <!-- calvin-status -->
        ## 📤 Calvin — Implementation Plan

        #{content}

        ---
        ### 📊 Token usage
        #{token_report}
      MD

      @github.post_status(@issue, comment)
    end

    # Crea il branch e scrive tutti i file via GitHub API
    def write_files_to_branch(files)
      branch = "agent/issue-#{@issue.number}"
      @github.create_branch(branch)

      files.each do |file|
        Calvin::LOG.info "writing #{file[:path]}"
        @github.create_or_update_file(
          file[:path],
          file[:content],
          "feat: implement issue ##{@issue.number} — #{file[:path]}",
          branch
        )
      end

      branch
    end

    # Apre la PR
    def open_pull_request(branch)
      pr = @github.create_pull_request(
        title: "[Agent] #{@issue.title}",
        body:  "Closes ##{@issue.number}\n\nImplemented by Calvin via Codestral.",
        head:  branch
      )
      pr.html_url
    end
  end
end
