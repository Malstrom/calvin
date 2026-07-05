# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.
#
# Routing:
#   CALVIN_FIX_MODE=true → CiFixFlow
#   label calvin          → ExploreFlow  (prompt da title+body)
#   default               → errore esplicito

require_relative "../lib/boot"

# ── Post-steps uniformi per tutti i flow ──────────────────────────────────────
def run_post_steps(result, github:, workflow:, ref:, extra: {})
  if result.success?
    r = result.value!
    Calvin::RubocopAutocorrect.run(
      files:  r[:files]  || [],
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
      explore_turns: r[:explore_turns],
      test_pass_pct: extra[:test_pass_pct]
    )
  else
    err = result.failure
    Calvin::LOG.error "FAILURE step=#{err[:step]} — #{err[:error]}"
    begin
      github.post_status(
        extra[:issue] || ref,
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
      explore_turns: err[:explore_turns],
      test_pass_pct: extra[:test_pass_pct]
    )
  end
end

# ── Fix mode (trigger da workflow ci-fix) ─────────────────────────────────────
if ENV["CALVIN_FIX_MODE"] == "true"
  pr_number   = ENV.fetch("PR_NUMBER").to_i
  pr_branch   = ENV.fetch("PR_BRANCH")
  test_output = File.read(ENV.fetch("TEST_OUTPUT_PATH", "/tmp/test-output.txt"))

  github = Calvin::GitHubClient.new(repo_root: "backend/api")
  Calvin::LOG.info "fix mode — PR ##{pr_number} branch: #{pr_branch}"

  result = Calvin::CiFixFlow.run(github, pr_number, pr_branch, test_output)
  Calvin::LOG.info "CiFixFlow result: #{result.success? ? result.value! : result.failure}"

  run_post_steps(result,
    github:   github,
    workflow: "calvin-fix",
    ref:      pr_number,
    extra:    { test_pass_pct: Calvin::TestOutputParser.pass_pct(test_output) }
  )

  exit(result.success? ? 0 : 1)
end

# ── Fetch issue ───────────────────────────────────────────────────────────────
temp_github = Calvin::GitHubClient.new
issue       = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
labels      = issue.labels.map(&:name)

repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
Calvin::LOG.info "labels: #{labels.join(', ')}"
Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

github = Calvin::GitHubClient.new(repo_root: repo_root)
Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"

# ── Calvin mode (ExploreFlow) ─────────────────────────────────────────────────
if labels.include?("calvin")
  Calvin::LOG.info "mode: calvin (ExploreFlow)"

  result = Calvin::ExploreFlow.run(github, issue)
  run_post_steps(result,
    github:   github,
    workflow: "calvin",
    ref:      issue.number,
    extra:    { issue: issue }
  )
  exit(result.success? ? 0 : 1)
end

# ── Nessuna label riconosciuta ────────────────────────────────────────────────
Calvin::LOG.error "Nessuna label Calvin riconosciuta su issue ##{issue.number} (labels: #{labels.join(', ')}). Usa la label 'calvin'."
exit(1)
