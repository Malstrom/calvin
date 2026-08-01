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

# ── Root del repo target: bootstrap dalle label, poi override da .calvin/calvin.yml ────
#
# Il bootstrap serve solo a costruire un primo Workspace per LEGGERE la config di
# progetto — che è l'unica fonte che sa dire con certezza dove vive .calvin/ (in un
# monorepo come synca sta sotto la app root, in un progetto singolo starà nella root).
bootstrap_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
Calvin::LOG.info "labels: #{labels.join(', ')}"
Calvin::LOG.info "bootstrap root: #{bootstrap_root.empty? ? '(nessuna)' : bootstrap_root}"

workspace      = Calvin::Workspace.new(repo_root: bootstrap_root)
root_workspace = bootstrap_root.empty? ? nil : Calvin::Workspace.new(repo_root: "")
Calvin.apply_project_config!(workspace, root_workspace: root_workspace)

# La config va letta una sola volta: se .calvin/calvin.yml dichiara una root diversa da
# quella bootstrap, si cambia solo il Workspace usato d'ora in poi — rileggere la config
# da una seconda root rischierebbe di non trovare più il file (se era stato trovato via
# root_workspace, cioè nella root del repo) e resettare @config silenziosamente ai default.
declared_root = Calvin.config[:root].to_s
repo_root     = declared_root.empty? ? bootstrap_root : declared_root

if repo_root != bootstrap_root
  Calvin::LOG.info "root dichiarata in .calvin/calvin.yml: #{repo_root} (override di #{bootstrap_root.empty? ? '(nessuna)' : bootstrap_root})"
  workspace = Calvin::Workspace.new(repo_root: repo_root)
end

Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

github    = Calvin::GitHubClient.new(repo_root: repo_root)
mistral   = Calvin::MistralClient.new
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
    mistral:   mistral
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
