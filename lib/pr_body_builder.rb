# frozen_string_literal: true
# Costruisce il body Markdown della PR.
# Estratto da commit_and_pr.rb — singola responsabilità.
#
# Struttura body:
#   1. Description prodotta da Codestral
#      (NON include What/Decisions/Alternatives/Risks — sezioni rimosse dal prompt
#       perché sprecano completion token senza valore per il reviewer)
#   2. Token usage breakdown per fase (explore + implement + totale)
#      La colonna 'cached' mostra i token serviti dalla cache Mistral (fatturati al 10%).
#      Appare solo per la fase explore (multi-turn). Implement non usa caching.
#   3. Due blocchi <details> collassabili con i chunk RAG:
#      - 🔍 RAG explore — regole usate durante la fase di esplorazione (query da issue)
#      - 🔍 RAG implement — regole usate durante la fase di codegen (query dai path file)
#   4. Footer: "Implemented by Calvin via Codestral <version>" + "Closes #N"
#
# Uso:
#   Calvin::PrBodyBuilder.build(issue:, usage:, usage_explore:, turns:,
#                               description:,
#                               retrieval_explore:, retrieval_implement:)  → String
#   Calvin::PrBodyBuilder.review_comment(usage:, review_text:)             → String

module Calvin
  module PrBodyBuilder
    def self.build(issue:, usage:, description: nil, usage_explore: nil, turns: nil,
                   retrieval_explore: nil, retrieval_implement: nil,
                   # retrocompatibilità: vecchio parametro :retrieval usato come explore
                   retrieval: nil)
      model_version = Calvin::MODEL.to_s

      # Retrocompatibilità: se arriva il vecchio :retrieval senza i nuovi, usalo come explore
      r_explore    = retrieval_explore || retrieval
      r_implement  = retrieval_implement

      description_section = description.to_s.strip.empty? \
        ? "_No description provided._"
        : description.to_s.strip

      parts = []
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

    # Body del commento di review postato da PrReviewFlow
    def self.review_comment(usage:, review_text: nil)
      model_version = Calvin::MODEL.to_s

      parts = []
      parts << review_text.to_s.strip unless review_text.to_s.strip.empty?
      parts << token_table(usage) if usage
      parts << "---"
      parts << "Reviewed by Calvin via Codestral (`#{model_version}`)."

      parts.join("\n\n")
    end

    # ── private ──────────────────────────────────────────────────────────────────────────

    # Token breakdown a 3 righe: explore | implement | totale.
    # La colonna 'cached' mostra i token serviti dal prefix cache Mistral.
    # Appare solo quando usage_explore è presente (fase explore multi-turn).
    # Se usage_explore è nil (chiamate legacy), ritorna la tabella singola senza cached.
    def self.token_table(usage, usage_explore: nil, turns: nil)
      pt = usage["prompt_tokens"]     || 0
      ct = usage["completion_tokens"] || 0
      tt = usage["total_tokens"]      || 0

      return single_row_table(pt, ct, tt) unless usage_explore

      ep  = usage_explore["prompt_tokens"]     || 0
      ec  = usage_explore["completion_tokens"] || 0
      et  = usage_explore["total_tokens"]      || 0
      cached = usage_explore["cached_tokens"].to_i

      tp_total = ep + pt
      tc_total = ec + ct
      tt_total = et + tt

      turns_label  = turns ? " (#{turns}t)" : ""
      cached_label = cached > 0 ? cached.to_s : "—"

      <<~TABLE.strip
        ### 📊 Token usage
        | fase | prompt | cached | completion | total |
        |------|--------|--------|------------|-------|
        | explore#{turns_label} | #{ep} | #{cached_label} | #{ec} | #{et} |
        | implement | #{pt} | — | #{ct} | #{tt} |
        | **totale** | **#{tp_total}** | **#{cached_label}** | **#{tc_total}** | **#{tt_total}** |
      TABLE
    end
    private_class_method :token_table

    def self.single_row_table(pt, ct, tt)
      <<~TABLE.strip
        ### 📊 Token usage
        | prompt | completion | total |
        |--------|------------|-------|
        | #{pt} | #{ct} | #{tt} |
      TABLE
    end
    private_class_method :single_row_table

    # Blocco <details> collassabile per una fase RAG.
    # Ritorna nil se retrieval è nil o non ha chunks — non emette il blocco.
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
