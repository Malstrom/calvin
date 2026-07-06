# frozen_string_literal: true
# Flusso Calvin — triggerato dalla label 'calvin'.
# Pipeline dry-transaction con 4 step espliciti:
#
#   build_prompt   — ContextBuilder costruisce il prompt dal title+body dell'issue
#   react_loop     — ReActLoop: il modello esplora e implementa
#   parse_files    — estrae FILE: blocks e PR_BODY
#   commit_and_pr  — branch + commit + PR
#
# Stack ("rails" | "flutter") determinato dalle label dell'issue.
# Default letto da CONFIG[:repo][:stacks][:default].
#
# Ritorna:
#   Success({ status: :success, pr_url:, branch:, files:, usage:, explore_turns: })
#   Failure({ step:, error:, usage:, explore_turns: })

require "dry/transaction"
require_relative "context_builder"
require_relative "file_parser"
require_relative "react_loop"
require_relative "commit_and_pr"

module Calvin
  class ExploreFlow
    include Dry::Transaction

    # Stacks e default letti da CONFIG — nessun valore hardcodato.
    KNOWN_STACKS  = (Calvin::CONFIG.dig(:repo, :stacks, :known)  || %w[rails flutter]).map(&:to_s).freeze
    DEFAULT_STACK = (Calvin::CONFIG.dig(:repo, :stacks, :default) || "rails").to_s.freeze

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
      Failure(step: :build_prompt, error: e.message, usage: nil, explore_turns: nil)
    end

    def react_loop(github:, issue:, prompt:)
      stack = detect_stack(issue)
      Calvin::LOG.info "ExploreFlow: avvio ReActLoop per issue ##{issue.number} (stack=#{stack})"
      result = ReActLoop.new(github, prompt, stack: stack).run
      Calvin::LOG.info "ReActLoop terminato in #{result[:turns]} turn(s)"
      Success(
        github:        github,
        issue:         issue,
        content:       result[:content],
        usage:         result[:usage],
        explore_turns: result[:turns]
      )
    rescue => e
      Failure(step: :react_loop, error: e.message, usage: nil, explore_turns: nil)
    end

    def parse_files(github:, issue:, content:, usage:, explore_turns:)
      files = FileParser.parse(content)
      if files.empty?
        return Failure(step: :parse_files, error: "nessun FILE: block prodotto dal modello", usage: usage, explore_turns: explore_turns)
      end

      pr_body = FileParser.parse_pr_body(content)
      Success(
        github:        github,
        issue:         issue,
        files:         files,
        pr_body:       pr_body,
        usage:         usage,
        explore_turns: explore_turns
      )
    rescue => e
      Failure(step: :parse_files, error: e.message, usage: usage, explore_turns: explore_turns)
    end

    def commit_and_pr(github:, issue:, files:, pr_body:, usage:, explore_turns:)
      result = CommitAndPr.call(
        files:       files,
        issue:       issue,
        github:      github,
        usage:       usage,
        description: pr_body
      )
      return Failure(result.failure.merge(explore_turns: explore_turns)) if result.failure?

      Success(result.value!.merge(usage: usage, explore_turns: explore_turns, status: :success))
    rescue => e
      Failure(step: :commit_and_pr, error: e.message, usage: usage, explore_turns: explore_turns)
    end

    def detect_stack(issue)
      labels = issue.labels.map(&:name)
      KNOWN_STACKS.find { |s| labels.include?(s) } || DEFAULT_STACK
    end
  end
end
