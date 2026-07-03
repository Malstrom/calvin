# frozen_string_literal: true
# Gestisce il flusso agent-aider con dry-monads Do notation.
#
# Steps:
#   fetch_agent_prompt → setup_branch → aider → rubocop autocorrect
#   → squash_commit → push_branch → open_pr
#
# In ogni caso (successo o failure) viene postato un report sull'issue
# e scritto il GITHUB_STEP_SUMMARY per il tab Summary del workflow.

require "dry/monads"
require "dry/monads/do"
require "shellwords"
require "json"
require "fileutils"

module Calvin
  class AiderFlow
    include Dry::Monads[:result]
    include Dry::Monads::Do.for(:run)

    TOKEN_USAGE_FILE = File.expand_path("../../data/token_usage.json", __FILE__)

    def initialize(github, issue)
      @github  = github
      @issue   = issue
      @journal = []
      @tokens  = {}
    end

    def run
      prompt    = yield step(:fetch_prompt) { fetch_agent_prompt }
      yield step(:setup_branch)             { setup_branch }
      aider_out = yield step(:aider)        { AiderRunner.new.apply(prompt) }
      @tokens   = aider_out[:tokens]
      yield step(:rubocop)                  { run_rubocop }
      yield step(:commit)                   { squash_commit }
      yield step(:push)                     { push_branch }
      pr_url    = yield step(:open_pr)      { open_pr }

      persist_token_usage
      post_report(:success, pr_url: pr_url, aider_stdout: aider_out[:stdout])
      Success(pr_url)
    end

    private

    def step(name, &block)
      result = block.call
      if result.failure?
        @journal << { step: name, status: :fail, detail: result.failure }
        post_report(:failure, failed_step: name)
      else
        @journal << { step: name, status: :ok }
      end
      result
    end

    def fetch_agent_prompt
      comments = @github.issue_comments(@issue)
      return Failure("Nessun commento trovato sull'issue ##{@issue.number}.") if comments.empty?

      comment = comments.last
      Calvin::LOG.info "agent-prompt: ultimo commento (#{comment.body.bytesize} bytes)"
      Success(comment.body)
    end

    def setup_branch
      slug    = @issue.title.downcase.gsub(/[^a-z0-9]+/, "-").slice(0, 40).chomp("-")
      @branch = "feat/#{slug}-#{@issue.number}"
      Calvin::LOG.info "Branch: #{@branch}"
      system("git", "checkout", "-b", @branch) ? Success(@branch) : Failure("git checkout -b #{@branch} fallito")
    end

    def run_rubocop
      Calvin::LOG.info "Rubocop autocorrect..."
      output = `bundle exec rubocop --autocorrect 2>&1`
      Calvin::LOG.info output.slice(0, 1_000)
      Success(:rubocop_done)
    end

    def squash_commit
      system("git", "add", "-A")
      diff = `git diff --cached --name-only`.strip
      if diff.empty?
        Calvin::LOG.warn "squash_commit: nessuna modifica da committare"
        return Success(:nothing_to_commit)
      end
      Calvin::LOG.info "squash_commit: #{diff.lines.count} file(s) staged"
      message = "feat: implement ##{@issue.number} — #{@issue.title}"
      system("git", "commit", "-m", message) ? Success(:committed) : Failure("git commit fallito")
    end

    def push_branch
      repo_url = "https://x-access-token:#{ENV.fetch('GITHUB_TOKEN')}@github.com/#{Calvin::REPO}.git"
      system("git", "remote", "set-url", "origin", repo_url)
      system("git", "push", "origin", @branch, "--force") ? Success(:pushed) : Failure("git push #{@branch} fallito")
    end

    def open_pr
      url = PrBuilder.new.open(branch: @branch, issue: @issue)
      url ? Success(url) : Failure("Creazione PR fallita per branch #{@branch}")
    end

    # Aggiorna data/token_usage.json con i token dell'esecuzione corrente.
    def persist_token_usage
      return if @tokens.empty?

      FileUtils.mkdir_p(File.dirname(TOKEN_USAGE_FILE))
      history = File.exist?(TOKEN_USAGE_FILE) ? JSON.parse(File.read(TOKEN_USAGE_FILE), symbolize_names: true) : { total_sent: 0, total_received: 0, total_cost_usd: 0.0, runs: [] }

      history[:total_sent]     = history[:total_sent].to_i     + @tokens[:sent].to_i
      history[:total_received] = history[:total_received].to_i + @tokens[:received].to_i
      history[:total_cost_usd] = (history[:total_cost_usd].to_f + @tokens[:cost_usd].to_f).round(6)
      history[:runs] << {
        issue:    @issue.number,
        sent:     @tokens[:sent],
        received: @tokens[:received],
        cost_usd: @tokens[:cost_usd],
        at:       Time.now.utc.iso8601
      }

      File.write(TOKEN_USAGE_FILE, JSON.pretty_generate(history))
      Calvin::LOG.info "Token usage aggiornato: #{@tokens.inspect}"
    rescue => e
      Calvin::LOG.warn "persist_token_usage: #{e.message}"
    end

    def post_report(outcome, pr_url: nil, failed_step: nil, aider_stdout: nil)
      md = build_report_md(outcome, pr_url: pr_url, failed_step: failed_step, aider_stdout: aider_stdout)
      write_step_summary(md)
      @github.post_status(@issue, md)
    rescue => e
      Calvin::LOG.error "post_report fallito: #{e.message}"
    end

    def build_report_md(outcome, pr_url:, failed_step:, aider_stdout:)
      icon   = outcome == :success ? "🟢" : "🔴"
      title  = outcome == :success ? "Calvin completato" : "Calvin fallito (`#{failed_step}`)"
      branch = @branch || "n/a"
      repo   = Calvin::REPO

      steps_table = @journal.map do |j|
        status_icon = j[:status] == :ok ? "✅" : "❌"
        detail = j[:detail] ? "\n> `#{j[:detail].to_s.slice(0, 300)}`" : ""
        "| #{status_icon} | `#{j[:step]}` |#{detail}"
      end.join("\n")

      issue_link = "[##{@issue.number} #{@issue.title}](https://github.com/#{repo}/issues/#{@issue.number})"
      pr_line    = pr_url ? "\n**PR:** [#{pr_url}](#{pr_url})" : ""

      token_section = if @tokens.any?
        sent     = @tokens[:sent]     || "?"
        received = @tokens[:received] || "?"
        cost     = @tokens[:cost_usd] ? "$#{'%.4f' % @tokens[:cost_usd]}" : "n/a"
        "\n**Token Aider:** #{sent} sent / #{received} received — costo #{cost}"
      else
        ""
      end

      aider_section = aider_stdout && !aider_stdout.to_s.empty? ? "\n\n<details><summary>Aider output</summary>\n\n```\n#{aider_stdout.to_s.slice(0, 3_000)}\n```\n</details>" : ""

      <<~MD
        <!-- calvin-status -->
        ## #{icon} #{title}

        **Branch:** `#{branch}`#{pr_line}
        **Issue:** #{issue_link}#{token_section}

        | | Step |
        |---|---|
        #{steps_table}
        #{aider_section}
      MD
    end

    def write_step_summary(md)
      summary_file = ENV["GITHUB_STEP_SUMMARY"]
      return unless summary_file
      File.write(summary_file, md, mode: "a")
    rescue => e
      Calvin::LOG.warn "write_step_summary: #{e.message}"
    end
  end
end
