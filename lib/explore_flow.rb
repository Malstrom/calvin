# frozen_string_literal: true
# Flusso Calvin — triggerato dalla label 'calvin'.
# Pipeline dry-transaction con step espliciti:
#
#   build_prompt      — ContextBuilder costruisce il prompt dal title+body dell'issue
#   react_loop        — ReActLoop: il modello esplora e implementa
#   parse_files       — estrae FILE: blocks e PR_BODY
#   commit_files      — branch + commit (senza aprire la PR)
#   rubocop           — autocorrect sul branch appena creato
#   [test_fix_loop]   — placeholder: verrà aggiunto in Step 5
#   open_pr           — apre la PR (con eventuali label se i test non passano)
#
# Stack ("rails" | "flutter") determinato dalle label dell'issue.
# Default: "rails".
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

    KNOWN_STACKS  = %w[rails flutter].freeze
    DEFAULT_STACK = "rails"

    step :build_prompt
    step :react_loop
    step :parse_files
    step :commit_files
    step :open_pr

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
      description = FileParser.parse_pr_body(content)
      Calvin::LOG.info "parse_files: #{files.size} file(s) — PR body: #{description ? 'trovato' : 'assente'}"
      Success(github: github, issue: issue, files: files, usage: usage, description: description, explore_turns: explore_turns)
    end

    def commit_files(github:, issue:, files:, usage:, description:, explore_turns:)
      CommitAndPr.commit_files(files, issue: issue, github: github).fmap do |r|
        { github: github, issue: issue, branch: r[:branch], files: r[:files],
          usage: usage, description: description, explore_turns: explore_turns,
          labels: [] }
      end.or { |f| Failure(f.merge(usage: usage, explore_turns: explore_turns)) }
    end

    # Step 5 aggiungerà qui il test fix loop tra commit_files e open_pr.
    # Per ora labels rimane [] e il flusso è identico al precedente.

    def open_pr(github:, issue:, branch:, files:, usage:, description:, explore_turns:, labels:)
      CommitAndPr.open_pr(
        branch,
        issue:       issue,
        github:      github,
        usage:       usage,
        description: description,
        labels:      labels
      ).fmap { |r| r.merge(status: :success, branch: branch, files: files, usage: usage, explore_turns: explore_turns) }
       .or   { |f| Failure(f.merge(usage: usage, explore_turns: explore_turns)) }
    end

    def detect_stack(issue)
      labels = Array(issue.labels).map { |l| l.is_a?(String) ? l : l[:name].to_s.downcase }
      KNOWN_STACKS.find { |s| labels.include?(s) } || DEFAULT_STACK
    end
  end
end
