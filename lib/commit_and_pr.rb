# frozen_string_literal: true
# Crea branch, committa i file e apre la PR.
# Singola responsabilità: I/O Git + GitHub API.
#
# Naming convention branch:
#   issue-{N}-calvin-{run_id}
# Esempio:
#   issue-100-calvin-15234567890
#
# Il run_id di GitHub Actions garantisce unicità anche se lo stesso workflow
# viene eseguito più volte sulla stessa issue.
#
# Naming PR title:
#   [Calvin] [TAG] Titolo issue
# (nessun URL in fondo — il link all'issue è nel body via "Closes #N")
#
# Uso:
#   Calvin::CommitAndPr.call(
#     files:         [ {path:, content:} ],
#     issue:         issue,
#     github:        github_client,
#     usage:         hash | nil,
#     description:   string | nil
#   ) → Success({ pr_url:, branch:, files: }) | Failure({ step:, error: })

require "dry/monads"
require_relative "pr_body_builder"

module Calvin
  module CommitAndPr
    include Dry::Monads[:result]
    extend self

    def call(files:, issue:, github:, usage: nil, description: nil)
      run_id    = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      branch    = build_branch(issue, run_id)
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")

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

      pr_title = build_pr_title(issue)

      pr = github.create_pull_request(
        title: pr_title,
        body:  PrBodyBuilder.build(issue: issue, usage: usage, description: description),
        head:  branch
      )

      Calvin::LOG.info "CommitAndPr: PR aperta — #{pr.html_url}"
      Success({ pr_url: pr.html_url, branch: branch, files: resolved })
    rescue => e
      Failure({ step: :commit_and_pr, error: e.message })
    end

    private

    # issue-100-calvin-15234567890
    def build_branch(issue, run_id)
      "issue-#{issue.number}-calvin-#{run_id}"
    end

    # [Calvin] [US-02] Declared Preferences — questionario 5 domande
    # (titolo preso verbatim dall'issue, senza URL)
    def build_pr_title(issue)
      "[Calvin] #{issue.title}"
    end
  end
end
