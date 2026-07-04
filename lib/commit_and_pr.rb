# frozen_string_literal: true
# Modulo condiviso tra ImplementFlow ed ExploreFlow.
#
# Espone:
#   commit_and_open_pr(files, issue:, branch_prefix:, usage:) → pr_url String
#
# Gestisce:
#   - risoluzione [timestamp] nei path delle migration
#   - rubocop --autocorrect su tutti i file .rb insieme (path reali su disco)
#   - creazione branch (agent/issue-{n}-{run_id})
#   - commit atomico via GitHubClient
#   - apertura PR con token report nel body
#
# Flusso rubocop:
#   1. Scrivi tutti i file generati su disco (path reali nella VM effimera)
#   2. Lancia rubocop --autocorrect una sola volta su tutti i .rb
#      → usa il Gemfile del progetto target (stessa versione della CI)
#      → rubocop vede il .rubocop.yml del progetto automaticamente
#   3. Rileggi i file corretti da disco
#   4. commit_files_atomically → API GitHub
#   La VM è usa-e-getta: nessun cleanup necessario.

require "fileutils"

module Calvin
  module CommitAndPr
    def commit_and_open_pr(files, issue:, branch_prefix: "agent", usage: nil)
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      run_id    = ENV.fetch("GITHUB_RUN_ID", Time.now.to_i.to_s)
      branch    = "#{branch_prefix}/issue-#{issue.number}-#{run_id}"

      resolved = files.map do |f|
        { path: f[:path].gsub("[timestamp]", timestamp), content: f[:content] }
      end

      corrected = rubocop_autocorrect(resolved)

      @github.create_branch(branch)
      Calvin::LOG.info "writing #{corrected.size} file(s) in atomic commit on #{branch}"

      @github.commit_files_atomically(
        corrected,
        message: "feat: implement issue ##{issue.number} \u2014 #{issue.title}",
        branch:  branch
      )

      pr = @github.create_pull_request(
        title: "[Agent] #{issue.title}",
        body:  pr_body(issue, usage),
        head:  branch
      )

      pr.html_url
    end

    private

    # Determina il comando rubocop corretto:
    # Usa il Gemfile del progetto target (Dir.pwd/Gemfile) se esiste,
    # così la versione è identica a quella usata dalla CI del target.
    # Fallback al Gemfile di Calvin solo se il target non ha un Gemfile.
    def rubocop_cmd
      target_gemfile = File.join(Dir.pwd, "Gemfile")
      if File.exist?(target_gemfile)
        "BUNDLE_GEMFILE=#{target_gemfile} bundle exec rubocop"
      else
        calvin_gemfile = ENV["BUNDLE_GEMFILE"]
        (calvin_gemfile && File.exist?(calvin_gemfile)) ? "BUNDLE_GEMFILE=#{calvin_gemfile} bundle exec rubocop" : "rubocop"
      end
    end

    # Scrive tutti i file su disco, lancia rubocop --autocorrect una sola volta
    # su tutti i .rb insieme, rilegge i contenuti corretti.
    # I file non .rb vengono restituiti invariati senza toccare il disco.
    def rubocop_autocorrect(files)
      rb_files = files.select { |f| f[:path].end_with?(".rb") }
      other    = files.reject { |f| f[:path].end_with?(".rb") }

      if rb_files.empty?
        Calvin::LOG.info "rubocop: nessun file .rb — skip"
        return files
      end

      # 1. Scrivi su disco (path reali)
      rb_files.each do |f|
        full_path = File.join(Dir.pwd, f[:path])
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, f[:content])
        Calvin::LOG.info "rubocop: scritto su disco #{f[:path]}"
      end

      # 2. Lancia rubocop --autocorrect su tutti i path insieme
      cmd_prefix = rubocop_cmd
      paths_str  = rb_files.map { |f| File.join(Dir.pwd, f[:path]) }.join(" ")
      cmd = "#{cmd_prefix} --autocorrect --no-color -f quiet #{paths_str} 2>&1"
      Calvin::LOG.info "rubocop: #{cmd[0..160]}"
      out = `#{cmd}`
      exit_code = $?.exitstatus

      # exit 0 = no offenses, exit 1 = offenses trovati e corretti, exit 2+ = errore
      if exit_code <= 1
        Calvin::LOG.info "rubocop autocorrect completato (exit #{exit_code})"
      else
        Calvin::LOG.warn "rubocop exit #{exit_code}: #{out[0..300]}"
      end

      # 3. Rileggi i file corretti da disco
      corrected_rb = rb_files.map do |f|
        full_path = File.join(Dir.pwd, f[:path])
        content   = File.exist?(full_path) ? File.read(full_path) : f[:content]
        { path: f[:path], content: content }
      end

      corrected_rb + other
    end

    def pr_body(issue, usage)
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

      <<~BODY
        Closes ##{issue.number}

        Implemented by Calvin via Codestral.

        #{token_section}
      BODY
    end
  end
end
