# frozen_string_literal: true
# Gestisce il flusso agent-aider con dry-monads Do notation.
#
# Steps:
#   fetch_agent_prompt -> setup_branch -> aider -> rubocop autocorrect
#   -> squash_commit -> push_branch -> open_pr
#
# In ogni caso (successo o failure) viene postato un report sull'issue
# e scritto il GITHUB_STEP_SUMMARY per il tab Summary del workflow.
#
# Token tracking:
#   Dopo ogni run aggiorna backend/api/.calvin/aider-usage.yml (dati)
#   e backend/api/.calvin/aider-usage.md (report Markdown leggibile).

require "dry/monads"
require "dry/monads/do"
require "shellwords"
require "yaml"
require "json"
require "fileutils"
require "time"

module Calvin
  class AiderFlow
    include Dry::Monads[:result]
    include Dry::Monads::Do.for(:run)

    USD_TO_EUR   = 0.93
    USAGE_YML    = "backend/api/.calvin/aider-usage.yml"
    USAGE_MD     = "backend/api/.calvin/aider-usage.md"
    REPO_WEB     = "https://github.com/#{ENV.fetch('GITHUB_REPOSITORY', 'Malstrom/synca')}"

    def initialize(github, issue)
      @github  = github
      @issue   = issue
      @journal = []
      @tokens  = {}
      @pr_url  = nil
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
      @pr_url   = pr_url

      update_usage_files
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

    # ─── Steps ───────────────────────────────────────────────────────────────

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
      message = "feat: implement ##{@issue.number} \u2014 #{@issue.title}"
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

    # ─── Token tracking ──────────────────────────────────────────────────────

    def update_usage_files
      return if @tokens.empty?

      data = load_usage_yml
      entry = build_entry
      data["runs"] ||= []
      data["runs"].unshift(entry)
      data["totals"] = compute_totals(data["runs"])
      data["config"] ||= { "usd_to_eur_rate" => USD_TO_EUR }

      write_usage_yml(data)
      write_usage_md(data)
      Calvin::LOG.info "Usage files aggiornati: sent=#{entry['sent_tokens']} received=#{entry['received_tokens']} eur=#{entry['cost_eur']}"
    rescue => e
      Calvin::LOG.warn "update_usage_files: #{e.message}"
    end

    def load_usage_yml
      File.exist?(USAGE_YML) ? (YAML.safe_load(File.read(USAGE_YML)) || {}) : {}
    end

    def build_entry
      cost_usd = @tokens[:cost_usd].to_f
      cost_eur = (cost_usd * USD_TO_EUR).round(4)
      pr_number = @pr_url ? @pr_url.split("/").last.to_i : nil

      {
        "issue_number" => @issue.number,
        "issue_title"  => @issue.title,
        "issue_url"    => "#{REPO_WEB}/issues/#{@issue.number}",
        "pr_number"    => pr_number,
        "pr_url"       => @pr_url,
        "branch"       => @branch,
        "sent_tokens"  => @tokens[:sent].to_i,
        "received_tokens" => @tokens[:received].to_i,
        "total_tokens" => @tokens[:sent].to_i + @tokens[:received].to_i,
        "cost_usd"     => cost_usd.round(4),
        "cost_eur"     => cost_eur,
        "created_at"   => Time.now.utc.iso8601
      }
    end

    def compute_totals(runs)
      total_sent     = runs.sum { |r| r["sent_tokens"].to_i }
      total_received = runs.sum { |r| r["received_tokens"].to_i }
      total_cost_usd = runs.sum { |r| r["cost_usd"].to_f }.round(4)
      total_cost_eur = runs.sum { |r| r["cost_eur"].to_f }.round(4)
      avg_cost_eur   = runs.any? ? (total_cost_eur / runs.size).round(4) : 0.0
      max_run        = runs.max_by { |r| r["cost_eur"].to_f }

      {
        "runs"           => runs.size,
        "sent_tokens"    => total_sent,
        "received_tokens" => total_received,
        "total_tokens"   => total_sent + total_received,
        "total_cost_usd" => total_cost_usd,
        "total_cost_eur" => total_cost_eur,
        "avg_cost_eur"   => avg_cost_eur,
        "most_expensive_issue" => max_run ? max_run["issue_number"] : nil,
        "last_updated_at" => Time.now.utc.iso8601
      }
    end

    def write_usage_yml(data)
      FileUtils.mkdir_p(File.dirname(USAGE_YML))
      File.write(USAGE_YML, data.to_yaml)
    end

    def write_usage_md(data)
      totals = data["totals"] || {}
      runs   = data["runs"]   || []
      repo   = ENV.fetch("GITHUB_REPOSITORY", "Malstrom/synca")

      rows = runs.first(30).map do |r|
        issue_link = "[##{r['issue_number']}](#{r['issue_url']})"
        pr_link    = r["pr_url"] ? "[##{r['pr_number']}](#{r['pr_url']})" : "-"
        date       = r["created_at"]&.slice(0, 10) || "-"
        "| #{issue_link} | #{pr_link} | `#{r['branch']}` | #{r['sent_tokens']} | #{r['received_tokens']} | #{r['total_tokens']} | #{r['cost_eur']} | #{date} |"
      end.join("\n")

      md = <<~MD
        # Calvin Aider usage

        <!-- aggiornato automaticamente da Calvin ad ogni run agent-aider -->

        ## Totali

        | Metrica | Valore |
        |---|---|
        | Run totali | #{totals['runs']} |
        | Token inviati | #{totals['sent_tokens']} |
        | Token ricevuti | #{totals['received_tokens']} |
        | Token complessivi | #{totals['total_tokens']} |
        | Costo totale USD | $#{totals['total_cost_usd']} |
        | Costo totale EUR | \u20ac#{totals['total_cost_eur']} |
        | Costo medio per run | \u20ac#{totals['avg_cost_eur']} |
        | Issue pi\u00f9 costosa | ##{totals['most_expensive_issue']} |
        | Ultimo aggiornamento | #{totals['last_updated_at']} |

        ## Ultimi run

        | Issue | PR | Branch | Sent | Received | Total | Cost \u20ac | Data |
        |---|---|---|---:|---:|---:|---:|---|
        #{rows}
      MD

      FileUtils.mkdir_p(File.dirname(USAGE_MD))
      File.write(USAGE_MD, md)
    end

    # ─── Report issue ────────────────────────────────────────────────────────

    def post_report(outcome, pr_url: nil, failed_step: nil, aider_stdout: nil)
      md = build_report_md(outcome, pr_url: pr_url, failed_step: failed_step, aider_stdout: aider_stdout)
      write_step_summary(md)
      @github.post_status(@issue, md)
    rescue => e
      Calvin::LOG.error "post_report fallito: #{e.message}"
    end

    def build_report_md(outcome, pr_url:, failed_step:, aider_stdout:)
      icon   = outcome == :success ? "\u{1F7E2}" : "\u{1F534}"
      title  = outcome == :success ? "Calvin completato" : "Calvin fallito (`#{failed_step}`)"
      branch = @branch || "n/a"
      repo   = Calvin::REPO

      steps_table = @journal.map do |j|
        status_icon = j[:status] == :ok ? "\u2705" : "\u274C"
        detail = j[:detail] ? "\n> `#{j[:detail].to_s.slice(0, 300)}`" : ""
        "| #{status_icon} | `#{j[:step]}` |#{detail}"
      end.join("\n")

      issue_link = "[##{@issue.number} #{@issue.title}](https://github.com/#{repo}/issues/#{@issue.number})"
      pr_line    = pr_url ? "\n**PR:** [#{pr_url}](#{pr_url})" : ""

      token_line = if @tokens.any?
        cost_eur = (@tokens[:cost_usd].to_f * USD_TO_EUR).round(4)
        "\n**Token Aider:** #{@tokens[:sent]} sent / #{@tokens[:received]} received \u2014 costo $#{@tokens[:cost_usd]} / \u20ac#{cost_eur}"
      else
        ""
      end

      usage_link = "\n**Usage stats:** [backend/api/.calvin/aider-usage.md](https://github.com/#{repo}/blob/main/backend/api/.calvin/aider-usage.md)"

      aider_section = aider_stdout && !aider_stdout.to_s.empty? ? "\n\n<details><summary>Aider output</summary>\n\n```\n#{aider_stdout.to_s.slice(0, 3_000)}\n```\n</details>" : ""

      <<~MD
        <!-- calvin-status -->
        ## #{icon} #{title}

        **Branch:** `#{branch}`#{pr_line}
        **Issue:** #{issue_link}#{token_line}#{usage_link}

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
