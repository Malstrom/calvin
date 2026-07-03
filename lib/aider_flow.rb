# frozen_string_literal: true
# Gestisce il flusso agent-aider con dry-monads Do notation.
#
# Il prompt viene letto dall'ultimo commento sull'issue.
# Non usa ContextBuilder né PromptBuilder.
#
# Steps:
#   fetch_agent_prompt → setup_branch → aider → rubocop autocorrect
#   → run_tests → squash_commit → push_branch → open_pr
#
# Il primo Failure interrompe il flusso. L'orchestratore gestisce
# l'errore finale via result.failure { |err| ... }.

require "dry/monads"
require "dry/monads/do"

module Calvin
  class AiderFlow
    include Dry::Monads[:result]
    include Dry::Monads::Do.for(:run)

    def initialize(github, issue)
      @github = github
      @issue  = issue
    end

    def run
      prompt = yield fetch_agent_prompt
      yield setup_branch
      yield AiderRunner.new.apply(prompt)
      yield run_rubocop
      yield run_tests
      yield squash_commit
      yield push_branch
      pr_url = yield open_pr

      @github.post_status(@issue, status_comment(pr_url))
      Success(pr_url)
    end

    private

    # Legge l'ultimo commento sull'issue e lo usa come prompt per Aider.
    def fetch_agent_prompt
      comments = @github.issue_comments(@issue)

      if comments.empty?
        return Failure("Nessun commento trovato sull'issue ##{@issue.number}. " \
                       "Aggiungi un commento con le istruzioni per Aider prima di aggiungere il label agent-aider.")
      end

      comment = comments.last
      Calvin::LOG.info "agent-prompt: ultimo commento (#{comment.body.bytesize} bytes)"
      Success(comment.body)
    end

    def setup_branch
      slug    = @issue.title.downcase.gsub(/[^a-z0-9]+/, "-").slice(0, 40).chomp("-")
      @branch = "feat/#{slug}-#{@issue.number}"
      Calvin::LOG.info "Branch: #{@branch}"
      system("git checkout -b #{@branch}") ? Success(@branch) : Failure("git checkout -b #{@branch} fallito")
    end

    # Autocorregge le offense rubocop. Non blocca il flusso se rimangono
    # offense non autocorregibili — è compito di Aider scrivere codice pulito.
    def run_rubocop
      Calvin::LOG.info "Rubocop autocorrect..."
      output = `bundle exec rubocop --autocorrect 2>&1`
      Calvin::LOG.info output.slice(0, 1_000)
      Success(:rubocop_done)
    end

    def run_tests
      Calvin::LOG.info "Running tests..."
      result = CiRunner.new.run

      if result.passed
        Calvin::LOG.info "Tests passed ✅"
        Success(:tests_passed)
      else
        Calvin::LOG.warn "Tests failed ❌"
        Failure("Tests falliti:\n#{result.output.slice(0, 4_000)}")
      end
    end

    # Raccoglie tutte le modifiche di Aider in un unico commit pulito.
    def squash_commit
      system("git add -A")
      diff = `git diff --cached --name-only`.strip

      if diff.empty?
        Calvin::LOG.warn "squash_commit: nessuna modifica da committare"
        return Success(:nothing_to_commit)
      end

      Calvin::LOG.info "squash_commit: #{diff.lines.count} file(s) staged"
      message = "feat: implement ##{@issue.number} — #{@issue.title}"
      system("git commit -m #{message.shellescape}") ? Success(:committed) : Failure("git commit fallito")
    end

    # Usa --force: i branch Calvin sono gestiti solo dal runner.
    def push_branch
      repo_url = "https://x-access-token:#{ENV.fetch('GITHUB_TOKEN')}@github.com/#{Calvin::REPO}.git"
      system("git remote set-url origin #{repo_url}")
      system("git push origin #{@branch} --force") ? Success(:pushed) : Failure("git push #{@branch} fallito")
    end

    def open_pr
      url = PrBuilder.new.open(branch: @branch, issue: @issue)
      url ? Success(url) : Failure("Creazione PR fallita per branch #{@branch}")
    end

    def status_comment(pr_url)
      <<~MD
        <!-- calvin-status -->
        **Calvin** · `#{@branch}`
        🟢 Tests passed · [PR aperta](#{pr_url})
      MD
    end
  end
end
