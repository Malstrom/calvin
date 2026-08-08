# frozen_string_literal: true
# Orchestratore Calvin — entry point unico per GitHub Actions.
#
# Routing:
#   ModeRouter.for_labels(labels) determina il mode dalla label dell'issue.
#   :explore_issue → ExploreFlow  (label "calvin" su issue synca)
#   :unknown       → errore esplicito
#
# Env:
#   ISSUE_NUMBER        — numero issue synca
#   GITHUB_TOKEN        — sempre richiesto
#   CALVIN_TARGET_PATH  — path del clone locale del repo target (default: workspace.target_path)
#   CALVIN_DRY_RUN      — se attivo: nessun commit, nessuna PR

require_relative "../lib/boot"

# ── Issue context ──────────────────────────────────────────────────────────────────────────────────
temp_github = Calvin::GitHubClient.new

issue  = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
labels = issue.labels.map(&:name)
Calvin::LOG.info "labels: #{labels.join(', ')}"

# Il profilo sta in `.calvin/` alla RADICE del repo target, non dentro l'applicazione:
# è proprio lui a dire dove l'applicazione si trova. Quindi si legge da un workspace sulla
# radice, e solo dopo si costruiscono workspace e client scopati su app_root.
profile   = Calvin::ProjectProfile.load(
  workspace: Calvin::Workspace.new(repo_root: ""),
  github:    temp_github,
  labels:    labels
)
repo_root = profile.app_root

github    = Calvin::GitHubClient.new(repo_root: repo_root)
mistral   = Calvin::MistralClient.new
workspace = Calvin::Workspace.new(repo_root: repo_root)
Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"
Calvin::LOG.info "workspace: #{workspace.available? ? workspace.root : "non disponibile (#{workspace.root}) — lettura via API"}"
Calvin::LOG.warn "DRY RUN attivo — nessuna scrittura su GitHub" if Calvin.dry_run?

mode = Calvin::ModeRouter.for_labels(labels)
Calvin::LOG.info "mode: #{mode}"

case mode
in :explore_issue
  stack  = labels.include?("flutter") ? "flutter" : "rails"
  result = Calvin::ExploreFlow.new.call(
    issue:     issue,
    github:    github,
    stack:     stack,
    workspace: workspace,
    mistral:   mistral,
    profile:   profile
  )
  Calvin::PostSteps.run(
    result,
    github:   github,
    mistral:  mistral,
    workflow: "calvin",
    ref:      issue.number,
    issue:    issue
  )
  exit(result.success? ? 0 : 1)

in :unknown
  Calvin::LOG.error "Nessuna label Calvin riconosciuta su issue ##{issue.number} (labels: #{labels.join(', ')}). Usa la label 'calvin'."
  exit(1)
end
