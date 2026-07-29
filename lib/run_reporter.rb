# frozen_string_literal: true
# Scrive le statistiche di ogni run Calvin in .calvin/reports/runs.csv nel repo target.
#
# Produce solo il CSV (runs.md rimosso — non aggiunge valore rispetto al CSV).
# I prezzi dei token vengono letti da Calvin::CONFIG — mai hardcodati.
# REPORTS_DIR e il branch di scrittura vengono letti da Calvin::CONFIG.
#
# Uso:
#   Calvin::RunReporter.write(
#     github:        @github,
#     workflow:      "calvin",
#     ref:           issue.number,
#     model:         "codestral-latest",
#     usage:         result[:usage],
#     usage_explore: result[:usage_explore],
#     status:        :success,
#     explore_turns: result[:explore_turns],
#     tests_written: result[:tests_written],
#     writer_errors: result[:writer_errors],
#     temperature:   result[:temperature],
#     files_written: result[:files_written],
#     issue_length:  issue.body.to_s.length
#   )

require "csv"

module Calvin
  module RunReporter
    REPORTS_DIR    = Calvin::CONFIG.dig(:repo, :reports_dir)    || ".calvin/reports"
    DEFAULT_BRANCH = Calvin::CONFIG.dig(:repo, :default_branch) || "main"

    CSV_PATH = "#{REPORTS_DIR}/runs.csv"

    CSV_HEADER = %w[
      run_at workflow ref model
      prompt_tokens cached_tokens_explore completion_tokens total_tokens
      cost_usd status explore_turns
      tests_written writer_errors
      temperature files_written issue_length
      validation validation_stage repair_attempts knowledge
    ].freeze

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
      usage_explore:  nil,
      explore_turns:  nil,
      tests_written:  nil,
      writer_errors:  nil,
      temperature:      nil,
      files_written:    nil,
      issue_length:     nil,
      validation_stage: nil,
      validation_ok:    nil,
      repair_attempts:  nil,
      knowledge:        nil
    )
      if Calvin.dry_run?
        Calvin::LOG.info "RunReporter: DRY RUN — report non scritto"
        return
      end

      pricing    = Calvin::CONFIG.dig(:pricing, :models) || {}
      prompt_tok  = usage&.fetch("prompt_tokens",     0).to_i
      compl_tok   = usage&.fetch("completion_tokens", 0).to_i
      total_tok   = usage&.fetch("total_tokens",      0).to_i
      cached_tok  = usage_explore&.fetch("cached_tokens", 0).to_i || 0
      cost_usd    = calculate_cost(prompt_tok, compl_tok, model, pricing)

      new_row = [
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        workflow,
        ref.to_s,
        model,
        prompt_tok.to_s,
        cached_tok > 0 ? cached_tok.to_s : nil,
        compl_tok.to_s,
        total_tok.to_s,
        cost_usd.to_s,
        status.to_s,
        explore_turns.nil? ? nil : explore_turns.to_s,
        tests_written.nil? ? nil : tests_written.to_s,
        writer_errors.nil? ? nil : writer_errors.to_s,
        temperature.nil?   ? nil : temperature.to_s,
        files_written.nil? ? nil : files_written.to_s,
        issue_length.nil?  ? nil : issue_length.to_s,
        validation_ok.nil? ? nil : (validation_ok ? "green" : "red"),
        validation_stage.nil?  ? nil : validation_stage.to_s,
        repair_attempts.nil?   ? nil : repair_attempts.to_s,
        knowledge.nil? ? nil : Array(knowledge).join("+")
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

      github.commit_files_atomically(
        [{ path: CSV_PATH, content: csv_content }],
        message: "chore: calvin run report — #{workflow} ref ##{ref}",
        branch:  DEFAULT_BRANCH
      )

      Calvin::LOG.info "RunReporter: report aggiornato (#{CSV_PATH}) — #{rows.size} righe totali"
    rescue => e
      Calvin::LOG.warn "RunReporter FAILED: #{e.class} — #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    end

    def self.calculate_cost(prompt_tok, compl_tok, model, pricing)
      p            = pricing[model.to_sym] || pricing[model] || {}
      input_price  = p[:input_per_million].to_f
      output_price = p[:output_per_million].to_f
      ((prompt_tok / 1_000_000.0) * input_price +
       (compl_tok  / 1_000_000.0) * output_price).round(6)
    end
    private_class_method :calculate_cost
  end
end
