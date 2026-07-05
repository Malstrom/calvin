# frozen_string_literal: true
# Flusso Calvin — triggerato dalla label 'calvin'.
# Pipeline dry-transaction con step espliciti:
#
#   build_prompt  — ContextBuilder costruisce il prompt dal title+body dell'issue
#   react_loop    — ReActLoop: il modello esplora e implementa
#   parse_files   — estrae FILE: blocks e PR_BODY
#   commit_files  — branch + commit (senza aprire la PR)
#   test_fix      — TestFixLoop: verifica + eventuale fix test prima di aprire la PR
#   open_pr       — apre la PR (con label 'needs-human-review' se i test non convergono)
#
# Stack ("rails" | "flutter") determinato dalle label dell'issue.
# Default: "rails".
#
# TestFixLoop viene saltato se CALVIN_RAILS_ROOT non è impostato
# (es. in ambienti non-CI o stack non-rails).
#
# Ritorna:
#   Success({ status: :success, pr_url:, branch:, files:, usage:, explore_turns: })
#   Failure({ step:, error:, usage:, explore_turns: })

module Calvin
  class ExploreFlow
    include Dry::Transaction

    KNOWN_STACKS       = %w[rails flutter].freeze
    DEFAULT_STACK      = "rails"
    HUMAN_REVIEW_LABEL = "needs-human-review"

    step :build_prompt
    step :react_loop
    step :parse_files
    step :commit_files
    step :test_fix
    step :open_pr

    def self.run(github, issue, mistral: nil)
      new.call(github: github, issue: issue, mistral: mistral)
    end

    private

    def build_prompt(github:, issue:, mistral:)
      prompt = ContextBuilder.build(issue, github_client: github)
      Success(github: github, issue: issue, mistral: mistral, prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, usage: nil, explore_turns: nil)
    end

    def react_loop(github:, issue:, mistral:, prompt:)
      stack = detect_stack(issue)
      Calvin::LOG.info "ExploreFlow: avvio ReActLoop per issue ##{issue.number} (stack=#{stack})"
      result = ReActLoop.new(github, prompt, stack: stack).run
      Calvin::LOG.info "ReActLoop terminato in #{result[:turns]} turn(s)"
      Success(
        github:        github,
        issue:         issue,
        mistral:       mistral,
        content:       result[:content],
        usage:         result[:usage],
        explore_turns: result[:turns]
      )
    rescue => e
      Failure(step: :react_loop, error: e.message, usage: nil, explore_turns: nil)
    end

    def parse_files(github:, issue:, mistral:, content:, usage:, explore_turns:)
      files = FileParser.parse(content)
      if files.empty?
        return Failure(step: :parse_files, error: "nessun FILE: block prodotto dal modello", usage: usage, explore_turns: explore_turns)
      end
      description = FileParser.parse_pr_body(content)
      Calvin::LOG.info "parse_files: #{files.size} file(s) — PR body: #{description ? 'trovato' : 'assente'}"
      Success(github: github, issue: issue, mistral: mistral, files: files, usage: usage, description: description, explore_turns: explore_turns)
    end

    def commit_files(github:, issue:, mistral:, files:, usage:, description:, explore_turns:)
      CommitAndPr.commit_files(files, issue: issue, github: github).fmap do |r|
        { github: github, issue: issue, mistral: mistral,
          branch: r[:branch], files: r[:files],
          usage: usage, description: description, explore_turns: explore_turns }
      end.or { |f| Failure(f.merge(usage: usage, explore_turns: explore_turns)) }
    end

    # Esegue il test fix loop se siamo in ambiente Rails CI (CALVIN_RAILS_ROOT impostato).
    # Aggiunge label e commento sull'issue se i test non convergono.
    def test_fix(github:, issue:, mistral:, branch:, files:, usage:, description:, explore_turns:)
      rails_root = ENV["CALVIN_RAILS_ROOT"]
      labels     = []

      if rails_root && mistral && detect_stack(issue) == "rails"
        max_attempts = Calvin::CONFIG.dig(:test_fix, :max_attempts) || 2
        loop_result  = TestFixLoop.new(
          branch:       branch,
          rails_root:   rails_root,
          github:       github,
          mistral:      mistral,
          max_attempts: max_attempts
        ).run

        unless loop_result[:passed]
          labels = [HUMAN_REVIEW_LABEL]
          github.add_issue_comment(issue.number, build_failure_comment(loop_result))
          Calvin::LOG.warn "TestFixLoop: test non convergono dopo #{loop_result[:attempts]} attempt(s) — label #{HUMAN_REVIEW_LABEL} aggiunta"
        end
      else
        Calvin::LOG.info "test_fix: skipped (CALVIN_RAILS_ROOT non impostato o stack non-rails)"
      end

      Success(github: github, issue: issue, branch: branch, files: files,
               usage: usage, description: description, explore_turns: explore_turns,
               labels: labels)
    rescue => e
      Calvin::LOG.warn "test_fix step error: #{e.class} — #{e.message}"
      Success(github: github, issue: issue, branch: branch, files: files,
               usage: usage, description: description, explore_turns: explore_turns,
               labels: [HUMAN_REVIEW_LABEL])
    end

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

    def build_failure_comment(loop_result)
      <<~MD
        ⚠️ **Calvin: test non convergono dopo #{loop_result[:attempts]} attempt(s)**

        I test non passano. La PR è aperta con label `needs-human-review`.

        <details>
        <summary>Ultimo output di <code>rails test</code></summary>

        ```
        #{loop_result[:last_output].to_s.lines.last(50).join}
        ```

        </details>
      MD
    end
  end
end
