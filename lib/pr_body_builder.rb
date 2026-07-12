# frozen_string_literal: true
# Costruisce il body Markdown della PR.
# Estratto da commit_and_pr.rb — singola responsabilità.
#
# Struttura body:
#   1. Description prodotta da Codestral
#      (NON include What/Decisions/Alternatives/Risks — sezioni rimosse dal prompt
#       perché sprecano completion token senza valore per il reviewer)
#   2. Token usage breakdown per fase (explore + implement + totale)
#   3. Blocco <details> collassabile con i chunk RAG iniettati (costruito da Calvin,
#      non da Codestral — zero token aggiuntivi)
#   4. Footer: "Implemented by Calvin via Codestral <version>" + "Closes #N"
#
# Uso:
#   Calvin::PrBodyBuilder.build(issue:, usage:, usage_explore:, turns:,
#                               description:, retrieval:)  → String
#   Calvin::PrBodyBuilder.review_comment(usage:, review_text:)              → String

module Calvin
  module PrBodyBuilder
    def self.build(issue:, usage:, description: nil, usage_explore: nil, turns: nil, retrieval: nil)
      model_version = Calvin::MODEL.to_s

      description_section = description.to_s.strip.empty? \
        ? "_No description provided._"
        : description.to_s.strip

      parts = []
      parts << description_section
      parts << token_table(usage, usage_explore: usage_explore, turns: turns) if usage
      parts << rag_details(retrieval) if retrieval
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

    # ── private ────────────────────────────────────────────────────────────────

    # Token breakdown a 3 righe: explore | implement | totale.
    # Se usage_explore è nil (es. chiamate legacy), ritorna la tabella singola.
    def self.token_table(usage, usage_explore: nil, turns: nil)
      pt = usage["prompt_tokens"]     || 0
      ct = usage["completion_tokens"] || 0
      tt = usage["total_tokens"]      || 0

      return single_row_table(pt, ct, tt) unless usage_explore

      ep  = usage_explore["prompt_tokens"]     || 0
      ec  = usage_explore["completion_tokens"] || 0
      et  = usage_explore["total_tokens"]      || 0

      tp_total = ep + pt
      tc_total = ec + ct
      tt_total = et + tt

      turns_label = turns ? " (#{turns}t)" : ""

      <<~TABLE.strip
        ### 📊 Token usage
        | fase | prompt | completion | total |
        |------|--------|------------|-------|
        | explore#{turns_label} | #{ep} | #{ec} | #{et} |
        | implement | #{pt} | #{ct} | #{tt} |
        | **totale** | **#{tp_total}** | **#{tc_total}** | **#{tt_total}** |
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

    # Blocco <details> collassabile con i chunk RAG iniettati.
    # Costruito da Calvin dai dati già disponibili — zero token aggiuntivi.
    # Se retrieval è nil o non ha chunks, emette "0 rules injected".
    def self.rag_details(retrieval)
      chunks = extract_chunks(retrieval)
      count  = chunks.size
      label  = count == 1 ? "1 rule injected" : "#{count} rules injected"

      rows = if chunks.any?
               chunks.map.with_index(1) do |chunk, i|
                 source     = chunk[:source_path] || chunk["source_path"] || "unknown"
                 similarity = chunk[:similarity]  || chunk["similarity"]
                 sim_fmt    = similarity ? format("%.2f", similarity.to_f) : "n/a"
                 content    = (chunk[:content] || chunk["content"]).to_s.strip
                 # Tronca il testo della regola a 120 chars per leggibilità
                 short = content.length > 120 ? "#{content[0..117]}..." : content
                 "| #{i} | #{short} | `#{source}` | #{sim_fmt} |"
               end.join("\n")
             else
               "| — | — | — | — |"
             end

      <<~DETAILS.strip
        <details>
        <summary>🔍 RAG context — #{label}</summary>

        | # | rule | source | similarity |
        |---|------|--------|------------|
        #{rows}

        </details>
      DETAILS
    end
    private_class_method :rag_details

    # Estrae i chunk grezzi da RetrievalResult.
    # RetrievalResult.rules è una String formattata — non abbiamo i chunk raw.
    # Se in futuro RetrievalResult espone :chunks, li usa direttamente.
    # Per ora ritorna array vuoto se non disponibile.
    def self.extract_chunks(retrieval)
      return [] unless retrieval
      return retrieval.chunks if retrieval.respond_to?(:chunks) && retrieval.chunks

      []
    end
    private_class_method :extract_chunks
  end
end
