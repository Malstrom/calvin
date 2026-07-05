# frozen_string_literal: true
# Scrive le statistiche di ogni run Calvin in .calvin/reports/ nel repo target.
#
# Produce due file (append CSV + regen MD) in un unico commit atomico.
# I prezzi dei token vengono letti da config/pricing.yml — mai hardcodati.
#
# Il GitHubClient passato come `github:` ha già il repo_root corretto
# (es. "backend/api"), quindi i file vengono scritti nel path giusto:
#   backend/api/.calvin/reports/runs.csv
#   backend/api/.calvin/reports/runs.md
#
# Uso:
#   Calvin::RunReporter.write(
#     github:        @github,           # GitHubClient del repo target (con repo_root)
#     workflow:      "calvin-auto",     # "calvin-auto" | "calvin-direct" | "calvin-fix"
#     ref:           issue.number,      # Integer — numero issue o PR
#     model:         "codestral-latest",
#     usage:         result[:usage],    # Hash o nil
#     status:        :success,          # :success | :failure | :fixed | :unfixable | :error
#     test_pass_pct: nil                # Float o nil
#   )

require "yaml"
require "csv"

module Calvin
  module RunReporter
    REPORTS_DIR  = ".calvin/reports"
    CSV_PATH     = "#{REPORTS_DIR}/runs.csv"
    MD_PATH      = "#{REPORTS_DIR}/runs.md"
    PRICING_PATH = File.expand_path("../../config/pricing.yml", __FILE__)

    CSV_HEADER = %w[
      run_at workflow ref model
      prompt_tokens completion_tokens total_tokens
      cost_usd status test_pass_pct
    ].freeze

    STATUS_EMOJI = {
      "success"   => "✅",
      "fixed"     => "✅",
      "failure"   => "❌",
      "error"     => "❌",
      "unfixable" => "⚠️"
    }.freeze

    def self.write(github:, workflow:, ref:, model:, usage:, status:, test_pass_pct: nil)
      pricing    = load_pricing
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
        test_pass_pct.nil? ? nil : test_pass_pct.to_s
      ]

      existing_csv = github.get_file_content(CSV_PATH)
      rows = if existing_csv
        CSV.parse(existing_csv, headers: true).map(&:fields)
      else
        []
      end
      rows << new_row

      csv_content = CSV.generate(force_quotes: false) do |csv|
        csv << CSV_HEADER
        rows.each { |r| csv << r }
      end

      md_content = build_md(rows)

      github.commit_files_atomically(
        [
          { path: CSV_PATH, content: csv_content },
          { path: MD_PATH,  content: md_content  }
        ],
        message: "chore: calvin run report — #{workflow} ref ##{ref}",
        branch:  "main"
      )

      Calvin::LOG.info "RunReporter: report aggiornato (#{CSV_PATH}) — #{rows.size} righe totali"
    rescue => e
      Calvin::LOG.warn "RunReporter FAILED: #{e.class} — #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    end

    # ── private ────────────────────────────────────────────────────────────────

    def self.load_pricing
      YAML.load_file(PRICING_PATH).fetch("models", {})
    rescue => e
      Calvin::LOG.warn "RunReporter: pricing.yml non leggibile — #{e.message}"
      {}
    end
    private_class_method :load_pricing

    def self.calculate_cost(prompt_tok, compl_tok, model, pricing)
      p = pricing[model] || {}
      input_price  = p["input_per_million"].to_f
      output_price = p["output_per_million"].to_f
      ((prompt_tok / 1_000_000.0) * input_price +
       (compl_tok  / 1_000_000.0) * output_price).round(6)
    end
    private_class_method :calculate_cost

    def self.build_md(rows)
      header = "| Date | Workflow | Ref | Model | Prompt tok | Completion tok | Total tok | Cost USD | Status | Test pass % |"
      sep    = "|------|----------|-----|-------|-----------|----------------|-----------|----------|--------|-------------|"

      table_rows = rows.map do |r|
        run_at, workflow, ref, model, pt, ct, tt, cost, status, pct = r
        date  = run_at.to_s[0..15].tr("T", " ")
        emoji = STATUS_EMOJI[status] || "❓"
        pct_s = pct.to_s.empty? ? "—" : "#{pct}%"
        "| #{date} | #{workflow} | \##{ref} | #{model} | #{format_num(pt)} | #{format_num(ct)} | #{format_num(tt)} | $#{cost} | #{emoji} #{status} | #{pct_s} |"
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
