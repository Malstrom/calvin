# frozen_string_literal: true
# Calvin::RepairLoop — chiude il ciclo fra validazione e generazione.
#
# Quando un gate del Validator è rosso, l'errore reale (output di ruby -c, rubocop,
# zeitwerk:check, db:migrate o dei test) torna al modello insieme ai soli file coinvolti.
# Il modello riscrive, la ladder rigira. Questo è ciò che trasforma Calvin da
# "genera e spera" in "genera finché non è verde".
#
# Vincoli espliciti al modello: correggere solo ciò che è rotto, non ampliare lo scope,
# riprodurre i file per intero (il diff-guard verifica che non perda righe).
#
# .call(files:, validation:, workspace:, github:, mistral:, file_plan:, originals:, issue:)
#   → { files:, validation:, attempts:, usage: }
#
# Il risultato contiene sempre l'ultima versione dei file e l'ultimo esito di validazione:
# se dopo max_attempts resta rosso, decide il chiamante (ExploreFlow) cosa fare.

require_relative "validator"
require_relative "file_parser"
require_relative "error_signature"
require_relative "learning_store"

module Calvin
  class RepairLoop
    REPAIR_SYSTEM = <<~PROMPT
      You are a senior Rails developer fixing code that failed automated validation.

      The files below were generated for a task and rejected by a validation gate.
      You receive the exact error output from the tool that rejected them.

      # Rules

      - Fix ONLY what the error output reports. Do not refactor, rename or improve anything else.
      - Do not change the scope of the implementation. Do not add features.
      - Output the COMPLETE file for every file you change — every line that was there before
        must still be there, unless the error requires removing it.
      - Never output a placeholder comment for omitted code. The file goes to disk verbatim.
      - If a file in the list needs no change, do not output a FILE block for it.

      # Output format

      For every file you fix, output exactly:

      FILE: path/to/file.rb
      <complete file content>

      No markdown fences. No commentary before or after the blocks.
    PROMPT

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(files:, validation:, workspace:, mistral:, github: nil,
                   file_plan: nil, originals: {}, issue: nil)
      @files      = Array(files)
      @validation = validation
      @workspace  = workspace
      @github     = github
      @mistral    = mistral
      @file_plan  = file_plan
      @originals  = originals || {}
      @issue      = issue
      @config     = Calvin::CONFIG[:repair] || {}
      @usage      = { "prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0 }
      @attempts   = 0
      @events     = []
    end

    def call
      return result if @validation.ok?

      max = @config[:max_attempts] || 3

      max.times do |i|
        @attempts = i + 1
        Calvin.phase_start(:repair, "attempt #{@attempts}/#{max}  gate=#{@validation.stage}")

        # L'evento va registrato prima di sapere l'esito: `fixed` viene aggiornato dopo la
        # rivalidazione. Così anche un run che si interrompe lascia traccia dell'errore.
        event = track(@validation, @attempts)

        if over_budget?
          Calvin::LOG.warn "RepairLoop: budget #{budget_limit}$ superato (#{format('%.4f', spent)}$) — stop"
          break
        end

        repaired = request_repair
        if repaired.empty?
          Calvin::LOG.warn "RepairLoop: il modello non ha prodotto FILE block — stop"
          break
        end

        @files = merge(@files, repaired)
        Calvin::LOG.info "RepairLoop: #{repaired.size} file riscritti — rivalidazione"

        @validation = Validator.call(
          files:     @files,
          workspace: @workspace,
          github:    @github,
          file_plan: @file_plan,
          originals: @originals,
          issue:     @issue
        )

        event[:fixed] = @validation.ok?

        if @validation.ok?
          Calvin.phase_end(:repair, "verde dopo #{@attempts} tentativo/i")
          return result
        end

        Calvin::LOG.warn "RepairLoop: ancora rosso su #{@validation.stage}"
      end

      Calvin.phase_end(:repair, "rosso su #{@validation.stage} dopo #{@attempts} tentativo/i")
      result
    end

    private

    def result
      persist_events
      { files: @files, validation: @validation, attempts: @attempts, usage: @usage, events: @events }
    end

    # ── apprendimento ──────────────────────────────────────────────────────────
    #
    # Ogni gate rosso è un dato: qui l'errore viene normalizzato in una firma
    # aggregabile, così bin/learn.rb può contare quali errori Calvin ripete davvero.

    def track(validation, attempt)
      path = Array(validation.failed_paths).first

      event = {
        gate:          validation.stage.to_s,
        signature:     Calvin::ErrorSignature.call(gate: validation.stage, output: validation.output),
        path:          path,
        scope:         path && Calvin::ErrorSignature.scope_for(path),
        error_excerpt: validation.output.to_s.lines.first(6).join.strip,
        fixed:         false,
        attempt:       attempt
      }

      Calvin::LOG.info "RepairLoop: signature=#{event[:signature]}#{event[:scope] ? " scope=#{event[:scope]}" : ''}"
      @events << event
      event
    end

    def persist_events
      return if @events.empty?
      return if Calvin.dry_run?

      Calvin::LearningStore.record(@events, issue_number: @issue&.number)
    end

    def budget_limit = @config[:max_cost_usd] || 1.0

    # Costo stimato con i prezzi in config — serve solo per fermarsi, non per il report.
    def spent
      pricing = Calvin::CONFIG.dig(:pricing, :models, Calvin::MODEL.to_sym) || {}
      inp     = (pricing[:input_per_million]  || 0.0) / 1_000_000.0
      out     = (pricing[:output_per_million] || 0.0) / 1_000_000.0
      @usage["prompt_tokens"] * inp + @usage["completion_tokens"] * out
    end

    def over_budget? = spent > budget_limit

    def request_repair
      response = @mistral.complete_messages(
        [
          { role: "system", content: REPAIR_SYSTEM },
          { role: "user",   content: build_user_message }
        ],
        temperature: 0.0
      )

      accumulate(response[:usage])
      Calvin::FileParser.parse(response[:content].to_s)
    rescue => e
      Calvin::LOG.warn "RepairLoop: chiamata al modello fallita — #{e.class}: #{e.message}"
      []
    end

    # Al modello vanno solo i file coinvolti dal gate rosso: mandare tutto invita a
    # riscrivere ciò che era già corretto.
    def build_user_message
      involved = involved_files
      sections = []

      sections << "## Failing gate\n#{@validation.stage}"
      sections << "## Error output\n```\n#{truncate(@validation.output, 12_000)}\n```"

      if @issue
        sections << "## Original task (for scope only — do not implement anything new)\n#{@issue.title}"
      end

      sections << "## Files\n"
      involved.each do |f|
        sections << "FILE: #{f[:path]}\n#{f[:content]}"
      end

      sections.join("\n\n")
    end

    def involved_files
      failed = Array(@validation.failed_paths).map(&:to_s)
      return @files if failed.empty?

      selected = @files.select { |f| failed.include?(f[:path].to_s) }
      selected.empty? ? @files : selected
    end

    # L'output rigenerato sostituisce la versione precedente; i file non ritoccati restano.
    def merge(current, repaired)
      by_path = current.to_h { |f| [f[:path].to_s, f] }
      repaired.each { |f| by_path[f[:path].to_s] = f }
      by_path.values
    end

    def accumulate(usage)
      return unless usage

      @usage["prompt_tokens"]     += usage["prompt_tokens"].to_i
      @usage["completion_tokens"] += usage["completion_tokens"].to_i
      @usage["total_tokens"]      += usage["total_tokens"].to_i
    end

    def truncate(text, limit)
      str = text.to_s
      return str if str.length <= limit

      "#{str[0, limit]}\n… (output troncato)"
    end
  end
end
