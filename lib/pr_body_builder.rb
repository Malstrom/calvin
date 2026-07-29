# frozen_string_literal: true
# Costruisce il body Markdown della PR.
# Estratto da commit_and_pr.rb — singola responsabilità.
#
# Struttura body:
#   1. Description prodotta da Codestral
#   2. Token usage breakdown per fase (explore + implement + totale)
#      Colonne: inviati | cached (×0.1) con % | generati | costo $
#      Il costo è calcolato con il cache discount al 10% (fonte: docs.mistral.ai/studio-api/conversations/advanced/prompt-caching)
#      Formula: (inviati - cached) × input_price + cached × input_price × 0.1 + generati × output_price
#   3. Due blocchi <details> collassabili con i chunk RAG
#   4. Footer: "Implemented by Calvin via Codestral <version>" + "Closes #N"
#
# Uso:
#   Calvin::PrBodyBuilder.build(issue:, usage:, usage_explore:, turns:,
#                               description:,
#                               retrieval_explore:, retrieval_implement:)  → String
#   Calvin::PrBodyBuilder.review_comment(usage:, review_text:)             → String
#   Calvin::PrBodyBuilder.test_comment(written, errors, skipped,
#                                      usage:, retrievals:)                → String

module Calvin
  module PrBodyBuilder
    CACHE_DISCOUNT = 0.1 # Mistral: cached token fatturati al 10% del prezzo input

    def self.build(issue:, usage:, description: nil, usage_explore: nil, turns: nil,
                   retrieval_explore: nil, retrieval_implement: nil,
                   retrieval: nil, validation: nil, repair_attempts: nil)
      model_version = Calvin::MODEL.to_s

      r_explore   = retrieval_explore || retrieval
      r_implement = retrieval_implement

      description_section = description.to_s.strip.empty? \
        ? "_No description provided._"
        : description.to_s.strip

      parts = []
      parts << validation_section(validation, repair_attempts) if validation
      parts << description_section
      parts << token_table(usage, usage_explore: usage_explore, turns: turns) if usage
      parts << rag_details(r_explore,   phase: "explore",   label: "RAG explore — rules used during exploration")
      parts << rag_details(r_implement, phase: "implement", label: "RAG implement — rules used during code generation")
      parts.compact!
      parts << "---"
      parts << "Implemented by Calvin via Codestral (`#{model_version}`)."
      parts << "Closes ##{issue.number}"

      parts.join("\n\n")
    end

    # Esito della validation ladder, in testa al body: è la prima cosa che un reviewer
    # deve sapere. Una PR verde dice quale livello di gate ha superato; una rossa mostra
    # l'output dell'errore, così non serve aprire i log del workflow.
    def self.validation_section(validation, repair_attempts)
      attempts = repair_attempts.to_i
      repair   = attempts.positive? ? " dopo #{attempts} tentativo/i di repair" : ""
      level    = Calvin::CONFIG.dig(:validation, :level) || "static"

      if validation.ok?
        "✅ **Validazione superata** (`#{level}`)#{repair} — gate eseguiti prima di aprire la PR."
      else
        <<~MD.strip
          ⚠️ **Validazione rossa sul gate `#{validation.stage}`**#{repair} — questa PR **non** è pronta al merge.

          <details><summary>Output del gate</summary>

          ```
          #{truncate_output(validation.output)}
          ```

          </details>
        MD
      end
    end

    OUTPUT_LIMIT = 6000

    def self.truncate_output(output)
      str = output.to_s.gsub("```", "'''")
      str.length > OUTPUT_LIMIT ? "#{str[0, OUTPUT_LIMIT]}\n… (troncato)" : str
    end
    private_class_method :truncate_output

    def self.review_comment(usage:, review_text: nil)
      model_version = Calvin::MODEL.to_s

      parts = []
      parts << review_text.to_s.strip unless review_text.to_s.strip.empty?
      parts << token_table(usage) if usage
      parts << "---"
      parts << "Reviewed by Calvin via Codestral (`#{model_version}`)."

      parts.join("\n\n")
    end

    # Commento test scritto sulla PR dopo TestFlow.
    # Mostra: stats (scritti/errori/saltati) + token usage aggregato + RAG chunks per ogni file.
    def self.test_comment(written, errors, skipped, usage: nil, retrievals: nil)
      model_version = Calvin::MODEL.to_s

      error_row = errors > 0 ? "| ❌ errori writer | #{errors} |\n        " : ""

      parts = []

      parts << <<~STATS.strip
        ### 🧪 Test generation
        | | |
        |---|---|
        | ✅ test scritti | #{written} |
        #{error_row}| ⏭️ saltati (non testabili) | #{skipped} |

        _I test sono stati generati da Calvin ma non eseguiti — verifica manuale necessaria._
      STATS

      # Token usage aggregato di tutti i TestWriter eseguiti
      parts << token_table(usage) if usage

      # RAG chunks — uno <details> collassabile per ogni file testato
      Array(retrievals).compact.each_with_index do |retrieval, idx|
        label = "RAG test — context injected (file #{idx + 1})"
        parts << rag_details(retrieval, phase: "test_#{idx}", label: label)
      end

      parts.compact!
      parts << "---"
      parts << "Tests generated by Calvin via Codestral (`#{model_version}`)."

      parts.join("\n\n")
    end

    # ── private ──────────────────────────────────────────────────────────────────────────

    def self.token_table(usage, usage_explore: nil, turns: nil)
      model   = Calvin::MODEL.to_s
      pricing = Calvin::CONFIG.dig(:pricing, :models) || {}
      p       = pricing[model.to_sym] || pricing[model] || {}
      inp     = p[:input_per_million].to_f  / 1_000_000.0
      out     = p[:output_per_million].to_f / 1_000_000.0

      pt = usage["prompt_tokens"]     || 0
      ct = usage["completion_tokens"] || 0

      return single_row_table(pt, ct, inp, out) unless usage_explore

      ep     = usage_explore["prompt_tokens"]     || 0
      ec     = usage_explore["completion_tokens"] || 0
      cached = usage_explore["cached_tokens"].to_i

      # costi
      cost_explore   = ((ep - cached) * inp) + (cached * inp * CACHE_DISCOUNT) + (ec * out)
      cost_implement = (pt * inp) + (ct * out)
      cost_total     = cost_explore + cost_implement

      # token totali
      tp_total = ep + pt
      tc_total = ec + ct
      ct_total = cached  # cached solo in explore

      # etichette
      turns_label  = turns ? " (#{turns}t)" : ""
      # `%%` sarebbe corretto dentro format(), qui è interpolazione: finiva nel body come "50%%".
      pct_explore  = ep > 0 ? " (#{(cached * 100.0 / ep).round}%)" : ""
      pct_total    = tp_total > 0 ? " (#{(ct_total * 100.0 / tp_total).round}%)" : ""
      cached_exp   = cached > 0 ? "#{cached}#{pct_explore}" : "—"
      cached_tot   = ct_total > 0 ? "#{ct_total}#{pct_total}" : "—"

      <<~TABLE.strip
        ### 📊 Token usage
        | fase | inviati | cached (×0.1) | generati | costo |
        |------|---------|----------------|----------|-------|
        | explore#{turns_label} | #{ep} | #{cached_exp} | #{ec} | $#{format('%.4f', cost_explore)} |
        | implement | #{pt} | — | #{ct} | $#{format('%.4f', cost_implement)} |
        | **totale** | **#{tp_total}** | **#{cached_tot}** | **#{tc_total}** | **$#{format('%.4f', cost_total)}** |
      TABLE
    end
    private_class_method :token_table

    def self.single_row_table(pt, ct, inp, out)
      cost = (pt * inp) + (ct * out)
      <<~TABLE.strip
        ### 📊 Token usage
        | inviati | generati | costo |
        |---------|----------|-------|
        | #{pt} | #{ct} | $#{format('%.4f', cost)} |
      TABLE
    end
    private_class_method :single_row_table

    def self.rag_details(retrieval, phase:, label:)
      return nil unless retrieval

      chunks = retrieval.chunks
      return nil if chunks.nil? || chunks.empty?

      count = chunks.size
      noun  = count == 1 ? "1 rule" : "#{count} rules"

      rows = chunks.map.with_index(1) do |chunk, i|
        source     = chunk["source_path"] || chunk[:source_path] || "unknown"
        similarity = chunk["similarity"]  || chunk[:similarity]
        sim_fmt    = similarity ? format("%.2f", similarity.to_f) : "n/a"
        content    = (chunk["content"] || chunk[:content]).to_s
                       .strip
                       .gsub(/\r?\n/, " ")
                       .gsub("|", "\\|")
        short      = content.length > 120 ? "#{content[0..117]}..." : content
        "| #{i} | #{short} | `#{source}` | #{sim_fmt} |"
      end.join("\n")

      <<~DETAILS.strip
        <details>
        <summary>🔍 #{label} — #{noun} injected</summary>

        | # | rule | source | similarity |
        |---|------|--------|------------|
        #{rows}

        </details>
      DETAILS
    end
    private_class_method :rag_details
  end
end
