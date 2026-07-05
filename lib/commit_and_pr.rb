# frozen_string_literal: true
# Crea branch, committa i file e apre la PR.
# Singola responsabilità: I/O Git + GitHub API.
#
# Espone due metodi pubblici separati per permettere al test fix loop
# di inserirsi tra il commit e l'apertura della PR:
#
#   CommitAndPr.commit_files(...)  → Success({ branch:, files: }) | Failure
#   CommitAndPr.open_pr(...)       → Success({ pr_url: })         | Failure
#
# Il metodo .call() è mantenuto per retrocompatibilità e compone i due.

require_relative "pr_body_builder"

module Calvin
  module CommitAndPr
    include Dry::Monads[:result]
    extend self

    def commit_files(files, issue:, github:, branch_prefix: nil)
      branch_prefix ||= Calvin::CONFIG[:branch_prefix] || "auto"
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      run_id    = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      branch    = "#{branch_prefix}/issue-#{issue.number}-#{run_id}"

      resolved = files.map do |f|
        { path: f[:path].gsub("[timestamp]", timestamp), content: f[:content] }
      end

      github.create_branch(branch)
      Calvin::LOG.info "CommitAndPr: #{resolved.size} file(s) su branch #{branch}"

      github.commit_files_atomically(
        resolved,
        message: "feat: implement issue ##{issue.number} — #{issue.title}",
        branch:  branch
      )

      Success({ branch: branch, files: resolved })
    rescue => e
      Failure({ step: :commit_files, error: e.message })
    end

    def open_pr(branch, issue:, github:, usage: nil, description: nil, labels: [])
      pr = github.create_pull_request(
        title:  "[Agent] #{issue.title}",
        body:   PrBodyBuilder.build(issue: issue, usage: usage, description: description),
        head:   branch,
        labels: labels
      )
      Calvin::LOG.info "CommitAndPr: PR aperta — #{pr.html_url}"
      Success({ pr_url: pr.html_url })
    rescue => e
      Failure({ step: :open_pr, error: e.message })
    end

    def call(files:, issue:, github:, branch_prefix: nil, usage: nil, description: nil)
      commit_files(files, issue: issue, github: github, branch_prefix: branch_prefix).bind do |r|
        open_pr(r[:branch], issue: issue, github: github, usage: usage, description: description)
          .fmap { |pr| r.merge(pr) }
      end
    end
  end
end
