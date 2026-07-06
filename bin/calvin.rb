# frozen_string_literal: true
# Orchestratore Calvin — entry point unico per GitHub Actions.
#
# Routing:
#   ModeRouter.for_labels(labels) determina il mode dalla label dell'issue o PR.
#   :explore_issue → ExploreFlow     (label "calvin" su issue synca)
#   :pr_review     → PrReviewFlow   (label "calvin-fix" su PR synca)
#   :unknown       → errore esplicito
#
# Env:
#   ISSUE_NUMBER          — numero issue synca (flusso issue)
#   PULL_REQUEST_NUMBER   — numero PR synca (flusso PR)
#   GITHUB_TOKEN          — sempre richiesto

require_relative "../lib/boot"
require_relative "../lib/pr_review_flow"

# ── Detect contesto: issue vs PR ───────────────────────────────────────────────
temp_github = Calvin::GitHubClient.new

if (pr_number_env = ENV["PULL_REQUEST_NUMBER"])
  # — PR context —
  pr_number = pr_number_env.to_i
  pr        = temp_github.fetch_pull_request(pr_number)
  labels    = pr.labels.map(&:name)

  repo_root = Calvin::REPO_ROOTS.values.first || ""
  Calvin::LOG.info "PR ##{pr_number} labels: #{labels.join(', ')}"
  Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

  github = Calvin::GitHubClient.new(repo_root: repo_root)
  Calvin::LOG.info "processing PR ##{pr_number}: #{pr.title}"

  mode = Calvin::ModeRouter.for_labels(labels)
  Calvin::LOG.info "mode: #{mode}"

  case mode
  in :pr_review
    pr_files = github.list_pull_request_files(pr_number)
    Calvin::LOG.info "PR files (#{pr_files.size}): #{pr_files.join(', ')}"

    result = Calvin::PrReviewFlow.run(github, pr, pr_files)
    Calvin::PostSteps.run(
      result,
      github:   github,
      workflow: "calvin-pr-fix",
      ref:      pr_number,
      issue:    nil
    )
    exit(result.success? ? 0 : 1)

  in :unknown
    Calvin::LOG.error "Nessuna label Calvin riconosciuta su PR ##{pr_number} (labels: #{labels.join(', ')}). Usa la label 'calvin-fix'."
    exit(1)
  end

else
  # — Issue context —
  issue  = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
  labels = issue.labels.map(&:name)

  repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
  Calvin::LOG.info "labels: #{labels.join(', ')}"
  Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

  github = Calvin::GitHubClient.new(repo_root: repo_root)
  Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"

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
end
