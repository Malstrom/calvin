# frozen_string_literal: true
# Modulo condiviso tra ImplementFlow ed ExploreFlow.
#
# Espone due operazioni:
#   commit_and_open_pr(files, issue:, branch_prefix:) → pr_url String
#
# Gestisce:
#   - risoluzione [timestamp] nei path delle migration
#   - creazione branch (agent/issue-{n}-{run_id})
#   - commit atomico via GitHubClient
#   - apertura PR

module Calvin
  module CommitAndPr
    def commit_and_open_pr(files, issue:, branch_prefix: "agent")
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      run_id    = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      branch    = "#{branch_prefix}/issue-#{issue.number}-#{run_id}"

      resolved = files.map do |f|
        { path: f[:path].gsub("[timestamp]", timestamp), content: f[:content] }
      end

      @github.create_branch(branch)
      Calvin::LOG.info "writing #{resolved.size} file(s) in atomic commit on #{branch}"

      @github.commit_files_atomically(
        resolved,
        message: "feat: implement issue ##{issue.number} \u2014 #{issue.title}",
        branch:  branch
      )

      pr = @github.create_pull_request(
        title: "[Agent] #{issue.title}",
        body:  "Closes ##{issue.number}\n\nImplemented by Calvin via Codestral.",
        head:  branch
      )
      pr.html_url
    end
  end
end
