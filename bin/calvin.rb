# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.

require "dry/monads"
require "octokit"
require "yaml"
require "fileutils"
require "logger"
require_relative "../lib/calvin_run"
require_relative "../lib/github_client"
require_relative "../lib/context_builder"
require_relative "../lib/prompt_builder"
require_relative "../lib/mistral_client"
require_relative "../lib/aider_runner"
require_relative "../lib/ci_runner"
require_relative "../lib/pr_builder"
require_relative "../lib/aider_flow"
require_relative "../lib/comment_flow"

module Calvin
  REPO = ENV.fetch("GITHUB_REPOSITORY")
  LOG  = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end
end

github     = Calvin::GitHubClient.new
issue      = github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
aider_mode = issue.labels.map(&:name).include?("agent-aider")

Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"
Calvin::LOG.info "mode: #{aider_mode ? 'aider' : 'comment'}"

result =
  if aider_mode
    Calvin::AiderFlow.new(github, issue).run
  else
    context = Calvin::ContextBuilder.build(issue)
    prompt  = Calvin::PromptBuilder.build(issue, context)
    Calvin::CommentFlow.new(github, issue, prompt).run
  end

result.failure do |err|
  Calvin::LOG.error "FAILURE: #{err}"
  begin
    github.post_status(issue, "\u{1F534} Calvin error\n\n```\n#{err}\n```")
  rescue => e
    Calvin::LOG.error "post_status fallito: #{e.message}"
  end
  exit 1
end
