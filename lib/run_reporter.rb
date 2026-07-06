# frozen_string_literal: true
# Scrive le statistiche di ogni run Calvin in .calvin/reports/ nel repo target.
#
# Produce due file (append CSV + regen MD) in un unico commit atomico.
# I prezzi dei token vengono letti da Calvin::CONFIG — mai hardcodati.
# REPORTS_DIR e il branch di scrittura vengono letti da Calvin::CONFIG.
#
# Il GitHubClient passato come `github:` ha già il repo_root corretto
# (es. "backend/api"), quindi i file vengono scritti nel path giusto:
#   backend/api/.calvin/reports/runs.csv
#   backend/api/.calvin/reports/runs.md
#
# Uso:
#   Calvin::RunReporter.write(
#     github:        @github,
#     workflow:      "calvin",
#     ref:           issue.number,
#     model:         "codestral-latest",
#     usage:         result[:usage],
#     status:        :success,
#     explore_turns: result[:explore_turns],   # opzionale, specifico ExploreFlow
#     temperature:   result[:temperature],
#     files_written: result[:files_written],
#     issue_length:  issue.body.to_s.length,   # opzionale, specifico ExploreFlow
#     test_pass_pct: nil                        # opzionale, futuro PrTestFixFlow
#   )

require "csv"

module Calvin
  module RunReporter
    # Path e branch letti da CONFIG — nessun valore hardcodato.
    REPORTS_DIR    = Calvin::CONFIG.dig(:repo, :reports_dir)    || ".calvin/reports"
    DEFAULT_BRANCH = Calvin::CONFIG.dig(:repo, :default_branch) || "main"

    CSV_PATH = "#{REPORTS_DIR}/runs.csv"
    MD_PATH  = "#{REPORTS_DIR}/runs.md"

    CSV_HEADER = %w[
      run_at workflow ref model
      prompt_tokens completion_tokens total_tokens
      cost_usd status explore_turns test_pass_pct
      temperature files_written issue_length
    ].freeze

    # explore_turns, test_pass_pct, issue_length sono opzionali e specifici
    # per singolo flow — vengono lasciati nil per i flow che non li producono.
    STATUS_EMOJI = {
      "success"   => "✅",
      "fixed"     => "✅",
      "failure"   => "❌",
      "error"     => "❌",
      "unfixable" => "⚠️"
    }.freeze

    def self.write(
      github:,
      workflow:,
      ref:,
      model:,
      usage:,
      status:,
      explore_turns: nil,
      test_pass_pct: nil,
      temperature:   nil,
      files_written: nil,
      issue_length:  nil
    )
      pricing    = Calvin::CONFIG.dig(:pricing, :models) || {}
      prompt_tok = usage&.fetch("prompt_tokens",     0).to_i
      compl_tok  = usage&.fetch("completion_tokens", 0).to_i
      total_tok  = usage&.fetch("total_tokens",      0).to_i
      cost_usd   = calculate_cost(prompt_tok, compl_tok, model, pricing)

      new_row = [
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        workflow,
        ref.to_s,
        model,
        prompt_tok.to_s,
        compl_tok.to_s,
        total_tok.to_s,
        cost_usd.to_s,
        status.to_s,
        explore_turns.nil? ? nil : explore_turns.to_s,
        test_pass_pct.nil? ? nil : test_pass_pct.to_s,
        temperature.nil?   ? nil : temperature.to_s,
        files_written.nil? ? nil : files_written.to_s,
        issue_length.nil?  ? nil : issue_length.to_s
      ]

      existing_csv = github.get_file_content(CSV_PATH)
      rows = if existing_csv
        CSV.parse(existing_csv.force_encoding("UTF-8"), headers: true).map(&:fields)
      else
        []
      end
      rows << new_row

      csv_content = CSV.generate(force_quotes: false) do |csv|
        csv << CSV_HEADER
        rows.each { |r| csv << r.fill(nil, r.size...CSV_HEADER.size) }
      end

      md_content = build_md(rows)

      github.commit_files_atomically(
        [
          { path: CSV_PATH, content: csv_content },
          { path: MD_PATH,  content: md_content  }
        ],
        message: "chore: calvin run report — #{workflow} ref ##{ref}",
        branch:  DEFAULT_BRANCH
      )

      Calvin::LOG.info "RunReporter: report aggiornato (#{CSV_PATH}) — #{rows.size} righe totali"
    rescue => e
      Calvin::LOG.warn "RunReporter FAILED: #{e.class} — #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    end

    # ── private ────────────────────────────────────────────────────────────────

    def self.calculate_cost(prompt_tok, compl_tok, model, pricing)
      p            = pricing[model.to_sym] || pricing[model] || {}
      input_price  = p[:input_per_million].to_f
      output_price = p[:output_per_million].to_f
      ((prompt_tok / 1_000_000.0) * input_price +
       (compl_tok  / 1_000_000.0) * output_price).round(6)
    end
    private_class_method :calculate_cost

    def self.build_md(rows)
      header = "| Date | Workflow | Ref | Model | Prompt tok | Completion tok | Total tok | Cost USD | Status | Explore turns | Test pass % | Temperature | Files written | Issue length |"
      sep    = "|------|----------|-----|-------|-----------|----------------|-----------|----------|--------|---------------|-------------|-------------|---------------|---------------|"

      table_rows = rows.map do |r|
        r = r.fill(nil, r.size...CSV_HEADER.size)
        run_at, workflow, ref, model, pt, ct, tt, cost, status,
          explore_turns, pct, temperature, files_written, issue_length = r
        date    = run_at.to_s[0..15].tr("T", " ")
        emoji   = STATUS_EMOJI[status] || "❓"
        pct_s   = pct.to_s.empty?            ? "—" : "#{pct}%"
        turns_s = explore_turns.to_s.empty?  ? "—" : explore_turns.to_s
        temp_s  = temperature.to_s.empty?    ? "—" : temperature.to_s
        files_s = files_written.to_s.empty?  ? "—" : files_written.to_s
        ilen_s  = issue_length.to_s.empty?   ? "—" : issue_length.to_s
        "| #{date} | #{workflow} | \##{ref} | #{model} | #{format_num(pt)} | #{format_num(ct)} | #{format_num(tt)} | $#{cost} | #{emoji} #{status} | #{turns_s} | #{pct_s} | #{temp_s} | #{files_s} | #{ilen_s} |"
      end

      lines = ["# Calvin Run Reports", "", header, sep] + table_rows + [""]
      lines.join("\n")
    end
    private_class_method :build_md

    def self.format_num(n)
      n.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\1 ').reverse
    end
    private_class_method :format_num
  end
end
