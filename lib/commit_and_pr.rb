# frozen_string_literal: true
# Crea branch, committa i file e apre la PR.
# Singola responsabilità: I/O Git + GitHub API.
#
# Non è più un mixin include — viene chiamato esplicitamente dai flow.
# PrBodyBuilder costruisce il body della PR.
#
# Uso:
#   Calvin::CommitAndPr.call(
#     files:         [ {path:, content:} ],
#     issue:         issue,
#     github:        github_client,
#     branch_prefix: nil,          # opzionale — default letto da CONFIG
#     usage:         hash | nil,
#     description:   string | nil
#   ) → Success({ pr_url:, branch:, files: }) | Failure({ step:, error: })

require "dry/monads"
require_relative "pr_body_builder"

module Calvin
  module CommitAndPr
    include Dry::Monads[:result]
    extend self

    # branch_prefix default letto da CONFIG — nessun valore hardcodato.
    DEFAULT_BRANCH_PREFIX = (Calvin::CONFIG.dig(:repo, :branch_prefix) || "auto").freeze

    def call(files:, issue:, github:, branch_prefix: nil, usage: nil, description: nil)
      prefix    = branch_prefix || DEFAULT_BRANCH_PREFIX
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      run_id    = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      branch    = "#{prefix}/issue-#{issue.number}-#{run_id}"

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

      pr = github.create_pull_request(
        title: "[Agent] #{issue.title}",
        body:  PrBodyBuilder.build(issue: issue, usage: usage, description: description),
        head:  branch
      )

      Calvin::LOG.info "CommitAndPr: PR aperta — #{pr.html_url}"
      Success({ pr_url: pr.html_url, branch: branch, files: resolved })
    rescue => e
      Failure({ step: :commit_and_pr, error: e.message })
    end
  end
end
