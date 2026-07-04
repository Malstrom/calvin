# frozen_string_literal: true
# Flusso di implementazione Calvin:
#   1. Inietta contenuto dei file `modified` nel prompt
#   2. Aggiunge sempre le istruzioni sul formato FILE:
#   3. Chiama Codestral (una sola chiamata)
#   4. Posta il commento sull'issue (lista file + token report)
#   5. Parsea i FILE: blocks dalla risposta
#   6. Risolve [timestamp] nei path delle migration
#   7. Scrive tutti i file in un unico commit atomico sul branch -> apre PR
#
# fix #8 — branch naming collision:
#   Il branch usa suffix con GITHUB_RUN_ID per evitare collisioni su run rilanciate.
#   Format: agent/issue-{number}-{run_id}
#
# .run → Success(pr_url) | Failure(msg)

require "dry/monads"
require_relative "file_parser"

module Calvin
  class ImplementFlow
    include Dry::Monads[:result]

    # Formato riga lista file: `- path/to/file.rb — modified` o `— new`
    FILE_LIST_PATTERN = /^-\s+(.+?)\s+[—-]+\s+(new|modified)$/i

    def initialize(github, issue, prompt)
      @github    = github
      @issue     = issue
      @prompt    = prompt
      @timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
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

    # Inietta i file `modified` esistenti e aggiunge SEMPRE le istruzioni sul formato FILE:
    def inject_existing_files(prompt)
      modified_paths = extract_modified_paths(prompt)

      injected = modified_paths.filter_map do |path|
        file_content = @github.get_file_content(path)
        next unless file_content

        Calvin::LOG.info "injecting existing file: #{path}"
        "---\n#{path}\n#{file_content}\n---"
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

    # Estrae i path dei file marcati come `modified` dalla lista nel prompt
    def extract_modified_paths(prompt)
      prompt.scan(FILE_LIST_PATTERN).filter_map do |path, status|
        path.strip if status.downcase == "modified"
      end
    end

    # Sostituisce [timestamp] nel path con il timestamp UTC reale.
    # Codestral a volte genera migration con [timestamp] letterale.
    def resolve_path(path)
      path.gsub("[timestamp]", @timestamp)
    end

    # Posta il commento sull'issue con il contenuto della risposta + token report
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
        ## \u{1F4E4} Calvin \u2014 Implementation Plan

        #{content}

        ---
        ### \u{1F4CA} Token usage
        #{token_report}
      MD

      @github.post_status(@issue, comment)
    end

    # fix #8 — branch naming collision:
    # Usa GITHUB_RUN_ID come suffix per garantire unicità su run rilanciate.
    def branch_name
      run_id = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      "agent/issue-#{@issue.number}-#{run_id}"
    end

    # Crea il branch e scrive tutti i file in un unico commit atomico.
    # Risolve i [timestamp] nei path prima di passare i file al client.
    def write_files_to_branch(files)
      branch = branch_name
      @github.create_branch(branch)

      resolved = files.map do |file|
        { path: resolve_path(file[:path]), content: file[:content] }
      end

      Calvin::LOG.info "writing #{resolved.size} file(s) in a single atomic commit"

      commit_message = "feat: implement issue ##{@issue.number} \u2014 #{@issue.title}"
      @github.commit_files_atomically(resolved, message: commit_message, branch: branch)

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
