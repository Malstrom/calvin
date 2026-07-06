# frozen_string_literal: true
# Entrypoint Calvin per fix di test falliti su PR.
#
# Attivato da .github/workflows/calvin-pr-fix.yml
# quando viene applicata la label `calvin-fix` su una PR di synca.
#
# Env richieste:
#   PULL_REQUEST_NUMBER  — numero della PR (es. 156)
#   GITHUB_TOKEN         — usato da GitHubClient via Octokit
#
# NON modifica bin/calvin.rb.

require_relative "../lib/boot"
require_relative "../lib/pr_review_flow"

pr_number = ENV.fetch("PULL_REQUEST_NUMBER").to_i
Calvin::LOG.info "PrFix entrypoint — PR ##{pr_number}"

# ── Bootstrap GitHub client ──────────────────────────────────────────────────
# repo_root: il repo synca è always "backend/api" per Rails —
# lo leggiamo da REPO_ROOTS cercando la chiave rails/synca.
# Se non trovato, usiamo la stringa vuota (nessun prefix).
repo_root = Calvin::REPO_ROOTS.values.first || ""
Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

github = Calvin::GitHubClient.new(repo_root: repo_root)

# ── Fetch PR ─────────────────────────────────────────────────────────────────
pr = github.fetch_pull_request(pr_number)
Calvin::LOG.info "PR ##{pr_number}: #{pr.title} (#{pr.head.ref})"

# Adatta l'oggetto Sawyer::Resource a un duck-type compatibile con PrReviewFlow
pr_duck = {
  number:      pr.number,
  head_branch: pr.head.ref
}

# ── File della PR (perimetro) ─────────────────────────────────────────────────
pr_files = github.list_pull_request_files(pr_number)
Calvin::LOG.info "PR files (#{pr_files.size}): #{pr_files.join(', ')}"

# ── Run flow ──────────────────────────────────────────────────────────────────
result = Calvin::PrReviewFlow.run(github, pr_duck, pr_files)

# ── Post steps ────────────────────────────────────────────────────────────────
# issue: nil — le PR non hanno post_status sull'issue
Calvin::PostSteps.run(
  result,
  github:   github,
  workflow: "calvin-pr-fix",
  ref:      pr_number,
  issue:    nil
)

exit(result.success? ? 0 : 1)
