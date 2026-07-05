# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.
#
# Routing:
#   CALVIN_FIX_MODE=true    → CiFixFlow  (label calvin-fix su PR)
#   CALVIN_AUTO_MODE=true   → ExploreFlow (label calvin-auto su issue)
#   default                 → ImplementFlow (label calvin-direct)

require "dry/monads"
require "octokit"
require "base64"
require "logger"
require_relative "../lib/github_client"
require_relative "../lib/context_builder"
require_relative "../lib/mistral_client"
require_relative "../lib/file_parser"
require_relative "../lib/commit_and_pr"
require_relative "../lib/implement_flow"
require_relative "../lib/explore_flow"
require_relative "../lib/ci_fix_flow"
require_relative "../lib/run_reporter"

module Calvin
  REPO = ENV.fetch("GITHUB_REPOSITORY")
  LOG  = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end

  REPO_ROOTS = {
    "rails"   => "backend/api",
    "flutter" => "frontend/mobile"
  }.freeze
end

# ── Helper: estrae % test passati dall'output Minitest ────────────────────────
def extract_test_pct(output)
  return nil if output.nil? || output.empty?
  m = output.match(/(\d+) runs, (\d+) failures/)
  return nil unless m
  runs, failures = m[1].to_i, m[2].to_i
  return nil if runs.zero?
  ((runs - failures) / runs.to_f * 100).round(1)
end

# ── Fix mode (label calvin-fix su PR) ───────────────────────────────────────
if ENV["CALVIN_FIX_MODE"] == "true"
  pr_number   = ENV.fetch("PR_NUMBER").to_i
  pr_branch   = ENV.fetch("PR_BRANCH")
  test_output = File.read(ENV.fetch("TEST_OUTPUT_PATH", "/tmp/test-output.txt"))

  github   = Calvin::GitHubClient.new(repo_root: "backend/api")
  fix_flow = Calvin::CiFixFlow.new(github, pr_number, pr_branch, test_output)
  Calvin::LOG.info "fix mode — PR ##{pr_number} branch: #{pr_branch}"

  result = fix_flow.run
  Calvin::LOG.info "CiFixFlow result: #{result}"

  Calvin::RunReporter.write(
    github:        github,
    workflow:      "calvin-fix",
    ref:           pr_number,
    model:         ENV.fetch("CALVIN_MODEL", "codestral-latest"),
    usage:         fix_flow.usage,
    status:        result,
    test_pass_pct: extract_test_pct(test_output)
  )

  exit(result == :error ? 1 : 0)
end

# ── Fetch issue (normal + auto mode) ───────────────────────────────────────────
temp_github = Calvin::GitHubClient.new
issue       = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
labels      = issue.labels.map(&:name)

repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

github = Calvin::GitHubClient.new(repo_root: repo_root)
Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"

# ── Auto mode (label calvin-auto) ─────────────────────────────────────────────
if ENV["CALVIN_AUTO_MODE"] == "true" || labels.include?("calvin-auto")
  Calvin::LOG.info "mode: auto (ReAct)"

  explore_flow = Calvin::ExploreFlow.new(github, issue)
  result       = explore_flow.run

  result.failure do |err|
    Calvin::LOG.error "FAILURE: #{err}"
    begin
      github.post_status(issue, "\u{1F534} Calvin error\n\n```\n#{err}\n```")
    rescue => e
      Calvin::LOG.error "post_status fallito: #{e.message}"
    end

    Calvin::RunReporter.write(
      github:   github,
      workflow: "calvin-auto",
      ref:      issue.number,
      model:    ENV.fetch("CALVIN_MODEL", "codestral-latest"),
      usage:    explore_flow.last_usage,
      status:   :failure
    )

    exit 1
  end

  Calvin::RunReporter.write(
    github:   github,
    workflow: "calvin-auto",
    ref:      issue.number,
    model:    ENV.fetch("CALVIN_MODEL", "codestral-latest"),
    usage:    explore_flow.last_usage,
    status:   :success
  )

  exit 0
end

# ── Direct mode (label calvin-direct, default) ─────────────────────────────
Calvin::LOG.info "mode: direct (ImplementFlow)"

prompt = begin
  Calvin::ContextBuilder.build(issue, github_client: github)
rescue => e
  Calvin::LOG.error "ContextBuilder: #{e.message}"
  github.post_status(issue, "\u{1F534} Calvin error\n\n```\n#{e.message}\n```")
  exit 1
end

implement_flow = Calvin::ImplementFlow.new(github, issue, prompt)
result         = implement_flow.run

result.failure do |err|
  Calvin::LOG.error "FAILURE: #{err}"
  begin
    github.post_status(issue, "\u{1F534} Calvin error\n\n```\n#{err}\n```")
  rescue => e
    Calvin::LOG.error "post_status fallito: #{e.message}"
  end

  Calvin::RunReporter.write(
    github:   github,
    workflow: "calvin-direct",
    ref:      issue.number,
    model:    ENV.fetch("CALVIN_MODEL", "codestral-latest"),
    usage:    implement_flow.last_usage,
    status:   :failure
  )

  exit 1
end

Calvin::RunReporter.write(
  github:   github,
  workflow: "calvin-direct",
  ref:      issue.number,
  model:    ENV.fetch("CALVIN_MODEL", "codestral-latest"),
  usage:    implement_flow.last_usage,
  status:   :success
)
