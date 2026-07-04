# frozen_string_literal: true
# Modulo condiviso tra ImplementFlow ed ExploreFlow.
#
# Espone:
#   commit_and_open_pr(files, issue:, branch_prefix:, usage:, description:) → pr_url String
#
# Gestisce:
#   - risoluzione [timestamp] nei path delle migration
#   - creazione branch (agent/issue-{n}-{run_id})
#   - commit atomico via GitHubClient
#   - apertura PR con description e token report nel body

require "fileutils"

module Calvin
  module CommitAndPr
    def commit_and_open_pr(files, issue:, branch_prefix: "agent", usage: nil, description: nil)
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
        message: "feat: implement issue ##{issue.number} — #{issue.title}",
        branch:  branch
      )

      pr = @github.create_pull_request(
        title: "[Agent] #{issue.title}",
        body:  pr_body(issue, usage, description: description),
        head:  branch
      )

      pr.html_url
    end

    private

    def pr_body(issue, usage, description: nil)
      token_section = if usage
        pt = usage["prompt_tokens"]     || 0
        ct = usage["completion_tokens"] || 0
        tt = usage["total_tokens"]      || 0
        <<~TABLE
          ### 📊 Token usage
          | prompt | completion | total |
          |--------|------------|-------|
          | #{pt} | #{ct} | #{tt} |
        TABLE
      else
        ""
      end

      description_section = description || "_No description provided by agent._"

      <<~BODY
        Closes ##{issue.number}

        Implemented by Calvin via Codestral.

        #{description_section}

        #{token_section}
      BODY
    end
  end
end
