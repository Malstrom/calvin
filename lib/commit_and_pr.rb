# frozen_string_literal: true
# Modulo condiviso tra ImplementFlow ed ExploreFlow.
#
# Espone:
#   commit_and_open_pr(files, issue:, branch_prefix:, usage:, description:) → pr_url String
#
# Gestisce:
#   - risoluzione [timestamp] nei path delle migration
#   - creazione branch (agent/issue-{n}-{run_id})
#   - commit atomico via GitHubClient
#   - rubocop --autocorrect su tutti i .rb committati (secondo commit separato)
#   - apertura PR con description e token report nel body

require "fileutils"
require "tempfile"
require "tmpdir"

module Calvin
  module CommitAndPr
    def commit_and_open_pr(files, issue:, branch_prefix: "agent", usage: nil, description: nil)
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      run_id    = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      branch    = "#{branch_prefix}/issue-#{issue.number}-#{run_id}"

      resolved = files.map do |f|
        { path: f[:path].gsub("[timestamp]", timestamp), content: f[:content] }
      end

      @github.create_branch(branch)
      Calvin::LOG.info "writing #{resolved.size} file(s) in atomic commit on #{branch}"

      @github.commit_files_atomically(
        resolved,
        message: "feat: implement issue ##{issue.number} — #{issue.title}",
        branch:  branch
      )

      rubocop_commit(resolved, issue: issue, branch: branch)

      pr = @github.create_pull_request(
        title: "[Agent] #{issue.title}",
        body:  pr_body(issue, usage, description: description),
        head:  branch
      )

      pr.html_url
    end

    private

    # Esegue rubocop --autocorrect sui file .rb del commit.
    # Se ci sono correzioni le committa come secondo commit separato sul branch.
    # Mai blocca: qualsiasi errore viene loggato e ignorato.
    def rubocop_commit(files, issue:, branch:)
      rb_files = files.select { |f| f[:path].end_with?(".rb") }
      return if rb_files.empty?

      Dir.mktmpdir("calvin-rubocop-") do |tmpdir|
        # Scrivi i file nella tmpdir rispettando la struttura delle cartelle
        rb_files.each do |f|
          dest = File.join(tmpdir, f[:path])
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, f[:content])
        end

        # Cerca .rubocop.yml nella working dir del runner (repo target clonato)
        rubocop_config = find_rubocop_config
        rubocop_cmd = rubocop_config ? "rubocop --config #{rubocop_config}" : "rubocop"

        # Esegue rubocop --autocorrect su tutti i file .rb nella tmpdir
        targets = rb_files.map { |f| File.join(tmpdir, f[:path]) }.join(" ")
        output  = `#{rubocop_cmd} --autocorrect --format quiet #{targets} 2>&1`
        Calvin::LOG.info "rubocop: #{output.strip.split("\n").last}"

        # Confronta prima/dopo e raccoglie solo i file effettivamente modificati
        corrected = rb_files.filter_map do |f|
          dest         = File.join(tmpdir, f[:path])
          new_content  = File.read(dest)
          new_content == f[:content] ? nil : { path: f[:path], content: new_content }
        end

        if corrected.empty?
          Calvin::LOG.info "rubocop: nessuna correzione necessaria"
          return
        end

        Calvin::LOG.info "rubocop: #{corrected.size} file(s) corretti — secondo commit"
        @github.commit_files_atomically(
          corrected,
          message: "chore: rubocop autocorrect (##{issue.number})",
          branch:  branch
        )
      end
    rescue => e
      Calvin::LOG.warn "rubocop_commit FAILED (non bloccante): #{e.class} — #{e.message}"
    end

    def find_rubocop_config
      candidate = File.join(Dir.pwd, ".rubocop.yml")
      File.exist?(candidate) ? candidate : nil
    end

    def pr_body(issue, usage, description: nil)
      token_section = if usage
        pt = usage["prompt_tokens"]     || 0
        ct = usage["completion_tokens"] || 0
        tt = usage["total_tokens"]      || 0
        <<~TABLE
          ### 📊 Token usage
          | prompt | completion | total |
          |--------|------------|-------|
          | #{pt} | #{ct} | #{tt} |
        TABLE
      else
        ""
      end

      description_section = description || "_No description provided by agent._"

      <<~BODY
        Closes ##{issue.number}

        Implemented by Calvin via Codestral.

        #{description_section}

        #{token_section}
      BODY
    end
  end
end
