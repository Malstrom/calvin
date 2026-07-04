# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.
#
# Routing:
#   CALVIN_FIX_MODE=true  → CiFixFlow  (label calvin-fix su PR)
#   label: calvin-direct  → ImplementFlow
#   default               → ImplementFlow

require "dry/monads"
require "octokit"
require "base64"
require "yaml"
require "fileutils"
require "logger"
require_relative "../lib/github_client"
require_relative "../lib/context_builder"
require_relative "../lib/mistral_client"
require_relative "../lib/file_parser"
require_relative "../lib/implement_flow"
require_relative "../lib/ci_fix_flow"

module Calvin
  REPO = ENV.fetch("GITHUB_REPOSITORY")
  LOG  = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end

  # Mappa label issue → prefisso path nel repo target
  REPO_ROOTS = {
    "rails"   => "backend/api",
    "flutter" => "frontend/mobile"
  }.freeze
end

# ── Fix mode (label calvin-fix su PR) ─────────────────────────────────────────
# Non fetcha issue — opera direttamente sulla PR e il suo branch.
if ENV["CALVIN_FIX_MODE"] == "true"
  pr_number   = ENV.fetch("PR_NUMBER").to_i
  pr_branch   = ENV.fetch("PR_BRANCH")
  test_output = File.read(ENV.fetch("TEST_OUTPUT_PATH", "/tmp/test-output.txt"))

  github = Calvin::GitHubClient.new(repo_root: "backend/api")
  Calvin::LOG.info "fix mode — PR ##{pr_number} branch: #{pr_branch}"

  result = Calvin::CiFixFlow.new(github, pr_number, pr_branch, test_output).run
  Calvin::LOG.info "CiFixFlow result: #{result}"
  exit(result == :error ? 1 : 0)
end

# ── Normal mode (calvin-direct) ────────────────────────────────────────────────
temp_github = Calvin::GitHubClient.new
issue       = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
labels      = issue.labels.map(&:name)

repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

github = Calvin::GitHubClient.new(repo_root: repo_root)
Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"

prompt = begin
  Calvin::ContextBuilder.build(issue, github_client: github)
rescue => e
  Calvin::LOG.error "ContextBuilder: #{e.message}"
  github.post_status(issue, "\u{1F534} Calvin error\n\n```\n#{e.message}\n```")
  exit 1
end

result = Calvin::ImplementFlow.new(github, issue, prompt).run

result.failure do |err|
  Calvin::LOG.error "FAILURE: #{err}"
  begin
    github.post_status(issue, "\u{1F534} Calvin error\n\n```\n#{err}\n```")
  rescue => e
    Calvin::LOG.error "post_status fallito: #{e.message}"
  end
  exit 1
end
