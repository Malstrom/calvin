# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.
#
# Routing:
#   CALVIN_FIX_MODE=true    → CiFixFlow   (label calvin-fix su PR)
#   CALVIN_AUTO_MODE=true   → ExploreFlow  (label calvin-auto su issue)
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
require_relative "../lib/rubocop_autocorrect"
require_relative "../lib/test_output_parser"

module Calvin
  REPO  = ENV.fetch("GITHUB_REPOSITORY")
  MODEL = ENV.fetch("CALVIN_MODEL", "codestral-latest")
  LOG   = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end

  REPO_ROOTS = {
    "rails"   => "backend/api",
    "flutter" => "frontend/mobile"
  }.freeze
end

# ── Post-steps uniformi per tutti i flow ──────────────────────────────────────
def run_post_steps(result, github:, workflow:, ref:, extra: {})
  if result.success?
    r = result.value!
    Calvin::RubocopAutocorrect.run(
      files:  r[:files] || [],
      branch: r[:branch] || "",
      github: github
    )
    Calvin::RunReporter.write(
      github:        github,
      workflow:      workflow,
      ref:           ref,
      model:         Calvin::MODEL,
      usage:         r[:usage],
      status:        r[:status] || :success,
      test_pass_pct: extra[:test_pass_pct]
    )
  else
    err = result.failure
    Calvin::LOG.error "FAILURE step=#{err[:step]} — #{err[:error]}"
    begin
      github.post_status(extra[:issue] || ref,
        "\u{1F534} Calvin error (#{err[:step]})\n\n```\n#{err[:error]}\n```"
      ) if extra[:issue]
    rescue => e
      Calvin::LOG.warn "post_status fallito: #{e.message}"
    end
    Calvin::RunReporter.write(
      github:        github,
      workflow:      workflow,
      ref:           ref,
      model:         Calvin::MODEL,
      usage:         err[:usage],
      status:        err[:status] || :failure,
      test_pass_pct: extra[:test_pass_pct]
    )
  end
end

# ── Fix mode (label calvin-fix su PR) ─────────────────────────────────────────
if ENV["CALVIN_FIX_MODE"] == "true"
  pr_number   = ENV.fetch("PR_NUMBER").to_i
  pr_branch   = ENV.fetch("PR_BRANCH")
  test_output = File.read(ENV.fetch("TEST_OUTPUT_PATH", "/tmp/test-output.txt"))

  github = Calvin::GitHubClient.new(repo_root: "backend/api")
  Calvin::LOG.info "fix mode — PR ##{pr_number} branch: #{pr_branch}"

  result = Calvin::CiFixFlow.new(github, pr_number, pr_branch, test_output).run
  Calvin::LOG.info "CiFixFlow result: #{result.success? ? result.value! : result.failure}"

  run_post_steps(result,
    github:   github,
    workflow: "calvin-fix",
    ref:      pr_number,
    extra:    { test_pass_pct: Calvin::TestOutputParser.pass_pct(test_output) }
  )

  github.remove_label_if_present(pr_number, "calvin-fix") rescue nil
  exit(result.success? ? 0 : 1)
end

# ── Fetch issue (normal + auto mode) ──────────────────────────────────────────
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

  result = Calvin::ExploreFlow.new(github, issue).run
  run_post_steps(result,
    github:   github,
    workflow: "calvin-auto",
    ref:      issue.number,
    extra:    { issue: issue }
  )
  exit(result.success? ? 0 : 1)
end

# ── Direct mode (label calvin-direct, default) ────────────────────────────────
Calvin::LOG.info "mode: direct (ImplementFlow)"

result = Calvin::ImplementFlow.new(github, issue).run
run_post_steps(result,
  github:   github,
  workflow: "calvin-direct",
  ref:      issue.number,
  extra:    { issue: issue }
)
exit(result.success? ? 0 : 1)
