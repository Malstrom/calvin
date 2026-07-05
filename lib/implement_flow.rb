# frozen_string_literal: true
# Flusso di implementazione Calvin (calvin-direct).
# Pipeline dry-transaction con 6 step espliciti:
#
#   build_prompt    — ContextBuilder legge issue + commenti
#   enrich_prompt   — inietta file esistenti + TEST CONTEXT
#   call_mistral    — chiamata Codestral
#   parse_files     — estrae FILE: blocks e PR_BODY
#   post_comment    — posta piano su issue
#   commit_and_pr   — branch + commit + PR
#
# Ritorna:
#   Success({ status: :success, pr_url:, branch:, files:, usage:, description: })
#   Failure({ step:, error:, usage: })

require "dry/transaction"
require_relative "context_builder"
require_relative "file_parser"
require_relative "test_context_injector"
require_relative "issue_commenter"
require_relative "commit_and_pr"

module Calvin
  class ImplementFlow
    include Dry::Transaction

    FILE_LIST_PATTERN   = /^-\s+(.+?)\s+[—-]+\s+(new|modified)$/i
    PROJECT_PROMPT_PATH = ".calvin/prompt"

    step :build_prompt
    step :enrich_prompt
    step :call_mistral
    step :parse_files
    step :post_comment
    step :commit_and_pr

    def initialize(github, issue)
      @github = github
      @issue  = issue
      @usage  = nil
      super()
    end

    attr_reader :usage

    private

    def build_prompt(_input)
      prompt = ContextBuilder.build(@issue, github_client: @github)
      Success(prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, usage: nil)
    end

    def enrich_prompt(prompt:)
      all_paths      = prompt.scan(FILE_LIST_PATTERN).map { |path, _| path.strip }
      modified_paths = prompt.scan(FILE_LIST_PATTERN).filter_map { |path, status|
        path.strip if status.downcase == "modified"
      }

      injected = modified_paths.filter_map do |path|
        content = @github.get_file_content(path)
        next unless content
        Calvin::LOG.info "enrich_prompt: injecting #{path}"
        "---\n#{path}\n#{content}\n---"
      end.join("\n\n")

      file_context = injected.empty? ? "" : "\n\n## EXISTING FILE CONTENTS\n\n#{injected}"

      test_context = if prompt.match?(/test\//i) || prompt.match?(/\btest\b/i)
        TestContextInjector.build(paths: all_paths, github: @github)
      else
        ""
      end

      project_conventions = begin
        extra = @github.get_file_content(PROJECT_PROMPT_PATH)
        extra ? "\n\n#{extra}" : ""
      end

      enriched = <<~PROMPT
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

      Success(prompt: enriched)
    rescue => e
      Failure(step: :enrich_prompt, error: e.message, usage: nil)
    end

    def call_mistral(prompt:)
      result = MistralClient.new.complete(prompt)
      @usage = result[:usage]
      Success(content: result[:content], usage: result[:usage])
    rescue => e
      Failure(step: :call_mistral, error: e.message, usage: nil)
    end

    def parse_files(content:, usage:)
      files = FileParser.parse(content)
      return Failure(step: :parse_files, error: "nessun FILE: block nella risposta", usage: usage) if files.empty?
      description = FileParser.parse_pr_body(content)
      Calvin::LOG.info "parse_files: #{files.size} file(s) — PR body: #{description ? 'trovato' : 'assente'}"
      Success(files: files, content: content, usage: usage, description: description)
    end

    def post_comment(files:, content:, usage:, description:)
      IssueCommenter.post(issue: @issue, content: content, usage: usage, github: @github)
      Success(files: files, usage: usage, description: description)
    rescue => e
      # Non bloccante: se il commento fallisce il flow continua
      Calvin::LOG.warn "post_comment FAILED (non bloccante): #{e.message}"
      Success(files: files, usage: usage, description: description)
    end

    def commit_and_pr(files:, usage:, description:)
      CommitAndPr.call(
        files:         files,
        issue:         @issue,
        github:        @github,
        branch_prefix: "agent",
        usage:         usage,
        description:   description
      ).fmap { |r| r.merge(status: :success, usage: usage) }
       .or { |f| Failure(f.merge(usage: usage)) }
    end
  end
end
