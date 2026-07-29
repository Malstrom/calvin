# frozen_string_literal: true
# Crea branch, committa i file e apre la PR.
# Singola responsabilità: I/O Git + GitHub API.
#
# Naming convention branch:
#   issue-{N}-calvin-{run_id}
# Esempio:
#   issue-100-calvin-15234567890
#
# Il run_id di GitHub Actions garantisce unicità anche se lo stesso workflow
# viene eseguito più volte sulla stessa issue.
#
# Naming PR title:
#   [Calvin] Titolo issue
# (nessun URL in fondo — il link all'issue è nel body via "Closes #N")
#
# Il placeholder [timestamp] nei path viene risolto con il timestamp della prossima
# migration valida (ultima esistente + 1), non con Time.now: un timestamp più basso di una
# migration già presente non verrebbe mai eseguito da db:migrate su un ambiente migrato.
#
# Con CALVIN_DRY_RUN attivo nulla viene scritto su GitHub: il metodo ritorna un esito
# simulato, usato da bin/eval.rb.
#
# Uso:
#   Calvin::CommitAndPr.call(
#     files:                [ {path:, content:} ],
#     issue:                issue,
#     github:               github_client,
#     usage:                hash | nil,
#     usage_explore:        hash | nil,
#     turns:                integer | nil,
#     retrieval_explore:    RetrievalResult | nil,
#     retrieval_implement:  RetrievalResult | nil,
#     validation:           Calvin::Validator::Result | nil,
#     repair_attempts:      integer | nil,
#     description:          string | nil
#   ) → Success({ pr_url:, branch:, files:, status: }) | Failure({ step:, error: })
#
# Retrocompatibilità: retrieval: ancora accettato come alias di retrieval_explore.

require "dry/monads"
require_relative "pr_body_builder"

module Calvin
  module CommitAndPr
    include Dry::Monads[:result]
    extend self

    def call(files:, issue:, github:, usage: nil, usage_explore: nil, turns: nil,
             retrieval_explore: nil, retrieval_implement: nil,
             retrieval: nil,        # retrocompatibilità — alias di retrieval_explore
             validation: nil, repair_attempts: nil,
             description: nil)
      run_id   = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      branch   = build_branch(issue, run_id)
      resolved = resolve_timestamps(files, github)

      pr_body = PrBodyBuilder.build(
        issue:                issue,
        usage:                usage,
        usage_explore:        usage_explore,
        turns:                turns,
        description:          description,
        retrieval_explore:    retrieval_explore || retrieval,
        retrieval_implement:  retrieval_implement,
        validation:           validation,
        repair_attempts:      repair_attempts
      )

      if Calvin.dry_run?
        Calvin::LOG.info "CommitAndPr: DRY RUN — nessun commit, nessuna PR (#{resolved.size} file)"
        return Success({ pr_url: nil, branch: branch, files: resolved, status: :dry_run })
      end

      github.create_branch(branch)
      Calvin::LOG.info "CommitAndPr: #{resolved.size} file(s) su branch #{branch}"

      github.commit_files_atomically(
        resolved,
        message: "feat: implement issue ##{issue.number} — #{issue.title}",
        branch:  branch
      )

      pr = github.create_pull_request(
        title: build_pr_title(issue),
        body:  pr_body,
        head:  branch
      )

      Calvin::LOG.info "CommitAndPr: PR aperta — #{pr.html_url}"
      Success({ pr_url: pr.html_url, branch: branch, files: resolved, status: :success })
    rescue => e
      Failure({ step: :commit_and_pr, error: e.message })
    end

    private

    # Sostituisce [timestamp] con la prossima versione di migration valida per il repo
    # target. Il fallback su Time.now vale solo se il repo non è leggibile.
    def resolve_timestamps(files, github)
      return files unless files.any? { |f| f[:path].to_s.include?("[timestamp]") }

      version = Calvin::ContextBuilder.next_migration_version(github)
      Calvin::LOG.info "CommitAndPr: [timestamp] → #{version}"

      files.map do |f|
        { path: f[:path].gsub("[timestamp]", version), content: f[:content] }
      end
    end

    # issue-100-calvin-15234567890
    def build_branch(issue, run_id)
      "issue-#{issue.number}-calvin-#{run_id}"
    end

    # [Calvin] Declared Preferences — questionario 5 domande
    # (titolo preso verbatim dall'issue, senza URL)
    def build_pr_title(issue)
      "[Calvin] #{issue.title}"
    end
  end
end
