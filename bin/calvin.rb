# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.

require "dry/monads"
require "octokit"
require "base64"
require "yaml"
require "fileutils"
require "logger"
require_relative "../lib/calvin_run"
require_relative "../lib/github_client"
require_relative "../lib/context_builder"
require_relative "../lib/prompt_builder"
require_relative "../lib/mistral_client"
require_relative "../lib/file_parser"
require_relative "../lib/implement_flow"
require_relative "../lib/comment_flow"
require_relative "../lib/aider_runner"
require_relative "../lib/ci_runner"
require_relative "../lib/pr_builder"
require_relative "../lib/aider_flow"

module Calvin
  REPO = ENV.fetch("GITHUB_REPOSITORY")
  LOG  = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end

  # Mappa label issue → prefisso path nel repo
  REPO_ROOTS = {
    "rails"   => "backend/api",
    "flutter" => "frontend/mobile"
  }.freeze
end

# Istanza temporanea senza repo_root per leggere l'issue e le sue label
temp_github = Calvin::GitHubClient.new
issue        = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
labels       = issue.labels.map(&:name)
aider_mode   = labels.include?("agent-aider")

# Determina il repo_root dalle label
repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

# Ricrea il client con il repo_root corretto
github = Calvin::GitHubClient.new(repo_root: repo_root)

Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"
Calvin::LOG.info "mode: #{aider_mode ? 'aider' : 'implement'}"

prompt = begin
  Calvin::ContextBuilder.build(issue, github_client: github)
rescue => e
  Calvin::LOG.error "ContextBuilder: #{e.message}"
  github.post_status(issue, "\u{1F534} Calvin error\n\n```\n#{e.message}\n```")
  exit 1
end

result =
  if aider_mode
    Calvin::AiderFlow.new(github, issue, prompt).run
  else
    Calvin::ImplementFlow.new(github, issue, prompt).run
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
