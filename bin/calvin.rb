# frozen_string_literal: true
# Orchestratore Calvin — entry point per GitHub Actions.
#
# Routing:
#   label calvin → ExploreFlow  (prompt da title+body)
#   default      → errore esplicito

require_relative "../lib/boot"

# ── Post-steps uniformi per tutti i flow ──────────────────────────────────────────────────────────────────────────
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
      temperature:   r[:temperature],
      files_written: Array(r[:files]).size,
      issue_length:  extra[:issue]&.body.to_s.length
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
      temperature:   err[:temperature],
      files_written: nil,
      issue_length:  extra[:issue]&.body.to_s.length
    )
  end
end

# ── Fetch issue ────────────────────────────────────────────────────────────────────────────────────────────
temp_github = Calvin::GitHubClient.new
issue       = temp_github.fetch_issue(ENV.fetch("ISSUE_NUMBER").to_i)
labels      = issue.labels.map(&:name)

repo_root = Calvin::REPO_ROOTS.find { |label, _| labels.include?(label) }&.last || ""
Calvin::LOG.info "labels: #{labels.join(', ')}"
Calvin::LOG.info "repo_root: #{repo_root.empty? ? '(none)' : repo_root}"

github  = Calvin::GitHubClient.new(repo_root: repo_root)
mistral = Calvin::MistralClient.new
Calvin::LOG.info "processing ##{issue.number}: #{issue.title}"

# ── Calvin mode (ExploreFlow) ────────────────────────────────────────────────────────────────────────────────────────────
if labels.include?("calvin")
  Calvin::LOG.info "mode: calvin (ExploreFlow)"

  result = Calvin::ExploreFlow.run(github, issue, mistral: mistral)
  run_post_steps(result,
    github:   github,
    workflow: "calvin",
    ref:      issue.number,
    extra:    { issue: issue }
  )
  exit(result.success? ? 0 : 1)
end

# ── Nessuna label riconosciuta ───────────────────────────────────────────────────────────────────────────────────────────────────────
Calvin::LOG.error "Nessuna label Calvin riconosciuta su issue ##{issue.number} (labels: #{labels.join(', ')}). Usa la label 'calvin'."
exit(1)
