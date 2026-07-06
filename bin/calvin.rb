# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.
#
# Routing:
#   ModeRouter.for_labels(labels) determina il mode dalla label dell'issue.
#   :explore_issue → ExploreFlow  (prompt da title+body)
#   :unknown       → errore esplicito

require_relative "../lib/boot"

# ── Fetch issue ────────────────────────────────────────────────────────────────────────────────────
temp_github = Calvin::GitHubClient.new
issue       = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
labels      = issue.labels.map(&:name)

repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
Calvin::LOG.info "labels: #{labels.join(', ')}"
Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

github = Calvin::GitHubClient.new(repo_root: repo_root)
Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"

# ── Routing via ModeRouter ───────────────────────────────────────────────────────────────────────────
mode = Calvin::ModeRouter.for_labels(labels)
Calvin::LOG.info "mode: #{mode}"

case mode
in :explore_issue
  result = Calvin::ExploreFlow.run(github, issue)
  Calvin::PostSteps.run(
    result,
    github:   github,
    workflow: "calvin",
    ref:      issue.number,
    issue:    issue
  )
  exit(result.success? ? 0 : 1)

in :unknown
  Calvin::LOG.error "Nessuna label Calvin riconosciuta su issue ##{issue.number} (labels: #{labels.join(', ')}). Usa la label 'calvin'."
  exit(1)
end
