# frozen_string_literal: true
# Flusso autonomo Calvin (calvin-auto / calvin-auto-body).
# Pipeline dry-transaction con 4 step espliciti:
#
#   build_prompt   — ContextBuilder costruisce il prompt (gestisce label, commenti, fallback)
#   react_loop     — ReActLoop: il modello esplora e implementa
#   parse_files    — estrae FILE: blocks e PR_BODY
#   commit_and_pr  — branch + commit + PR
#
# Ritorna:
#   Success({ status: :success, pr_url:, branch:, files:, usage: })
#   Failure({ step:, error:, usage: })

require "dry/transaction"
require_relative "context_builder"
require_relative "file_parser"
require_relative "react_loop"
require_relative "commit_and_pr"

module Calvin
  class ExploreFlow
    include Dry::Transaction

    step :build_prompt
    step :react_loop
    step :parse_files
    step :commit_and_pr

    def self.run(github, issue)
      new.call(github: github, issue: issue)
    end

    private

    def build_prompt(github:, issue:)
      prompt = ContextBuilder.build(issue, github_client: github)
      Success(github: github, issue: issue, prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, usage: nil)
    end

    def react_loop(github:, issue:, prompt:)
      Calvin::LOG.info "ExploreFlow: avvio ReActLoop per issue ##{issue.number}"
      result = ReActLoop.new(github, prompt).run
      Calvin::LOG.info "ReActLoop terminato in #{result[:turns]} turn(s)"
      Success(github: github, issue: issue, content: result[:content], usage: result[:usage])
    rescue => e
      Failure(step: :react_loop, error: e.message, usage: nil)
    end

    def parse_files(github:, issue:, content:, usage:)
      files = FileParser.parse(content)
      return Failure(step: :parse_files, error: "nessun FILE: block prodotto dal modello", usage: usage) if files.empty?
      description = FileParser.parse_pr_body(content)
      Calvin::LOG.info "parse_files: #{files.size} file(s) — PR body: #{description ? 'trovato' : 'assente'}"
      Success(github: github, issue: issue, files: files, usage: usage, description: description)
    end

    def commit_and_pr(github:, issue:, files:, usage:, description:)
      CommitAndPr.call(
        files:         files,
        issue:         issue,
        github:        github,
        branch_prefix: "auto",
        usage:         usage,
        description:   description
      ).fmap { |r| r.merge(status: :success, usage: usage) }
       .or { |f| Failure(f.merge(usage: usage)) }
    end
  end
end
