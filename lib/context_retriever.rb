# frozen_string_literal: true
# ContextRetriever — recupera regole rilevanti da Supabase prima del ReActLoop.
#
# Interfaccia pubblica:
#   ContextRetriever.call(issue) => RetrievalResult
#
# RetrievalResult = Data.define(:rules, :context)
#   .rules   => String formattata con le regole attive, o nil se nessuna trovata
#   .context => nil (predisposto per source_type futuri)
#
# Flusso:
#   1. Costruisce query testuale da issue.title + issue.body (primi 2000 char)
#   2. Chiama mistral-embed per ottenere l'embedding della query (1024 dim)
#   3. Chiama RPC calvin_rules_search su Supabase (top_k dal CONFIG o nessun limite)
#   4. Ritorna RetrievalResult con regole formattate
#
# Se SUPABASE_URL o SUPABASE_SERVICE_KEY non sono presenti => .rules = nil silenzioso.
# Se Mistral o Supabase sono down => .rules = nil silenzioso.

require "net/http"
require "json"

module Calvin
  RetrievalResult = Data.define(:rules, :context)

  class ContextRetriever
    EMBED_URL    = URI("https://api.mistral.ai/v1/embeddings")
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20

    # Quanti caratteri del body includere nella query di embedding.
    # Le issue raffinate con refine_task hanno contenuto semantico rilevante
    # (Goal, Acceptance criteria, Touched files) spesso oltre i 500 chars.
    QUERY_BODY_LIMIT = 2000

    def self.call(issue)
      new.call(issue)
    end

    def call(issue)
      unless supabase_configured?
        Calvin::LOG.info "ContextRetriever: Supabase non configurato — skip"
        return RetrievalResult.new(rules: nil, context: nil)
      end

      query     = build_query(issue)
      Calvin::LOG.info "ContextRetriever: query = #{query[0..120]}..."
      Calvin::LOG.info "ContextRetriever: query_length = #{query.length} chars"

      embedding = embed(query)
      chunks    = search_rules(embedding)

      if chunks.empty?
        Calvin::LOG.info "ContextRetriever: nessuna regola trovata"
        return RetrievalResult.new(rules: nil, context: nil)
      end

      Calvin::LOG.info "ContextRetriever: #{chunks.size} regola/e recuperata/e"
      log_chunks(chunks)

      RetrievalResult.new(rules: format_rules(chunks), context: nil)
    rescue => e
      Calvin::LOG.warn "ContextRetriever: fallback silenzioso (#{e.message})"
      RetrievalResult.new(rules: nil, context: nil)
    end

    private

    def supabase_configured?
      ENV["SUPABASE_URL"] && ENV["SUPABASE_SERVICE_KEY"]
    end

    def build_query(issue)
      body_excerpt = issue.body.to_s[0..QUERY_BODY_LIMIT]
      "#{issue.title} #{body_excerpt}".strip
    end

    def embed(text)
      embed_model = rag_config(:embed_model) || "mistral-embed"

      http              = Net::HTTP.new(EMBED_URL.host, EMBED_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                    = Net::HTTP::Post.new(EMBED_URL)
      req["Content-Type"]    = "application/json"
      req["Authorization"]   = "Bearer #{ENV.fetch('MISTRAL_API_KEY')}"
      req["Accept-Encoding"] = "identity"
      req.body               = { model: embed_model, input: [text] }.to_json

      resp = http.request(req)
      raise "Mistral embed error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body).dig("data", 0, "embedding")
    end

    def search_rules(embedding)
      repo  = Calvin::REPO
      limit = rag_config(:top_k_rules)

      url = URI("#{ENV['SUPABASE_URL']}/rest/v1/rpc/calvin_rules_search")

      http              = Net::HTTP.new(url.host, url.port)
      http.use_ssl      = url.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      params = { query_embedding: embedding, target_repo: repo }
      params[:match_count] = limit if limit

      req                    = Net::HTTP::Post.new(url)
      req["Content-Type"]    = "application/json"
      req["apikey"]          = ENV["SUPABASE_SERVICE_KEY"]
      req["Authorization"]   = "Bearer #{ENV['SUPABASE_SERVICE_KEY']}"
      req["Accept-Encoding"] = "identity"
      req.body               = params.to_json

      resp = http.request(req)
      raise "Supabase RPC error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end

    def log_chunks(chunks)
      Calvin::LOG.info "ContextRetriever: ===== RULES RETRIEVED ====="
      chunks.each_with_index do |chunk, i|
        source_path = chunk["source_path"] || "unknown"
        similarity  = chunk["similarity"] ? format("%.4f", chunk["similarity"]) : "n/a"
        content     = chunk["content"].to_s.strip
        Calvin::LOG.info "ContextRetriever: [#{i + 1}/#{chunks.size}] #{source_path} (similarity=#{similarity})"
        Calvin::LOG.info "ContextRetriever: #{content}"
        Calvin::LOG.info "ContextRetriever: -----"
      end
      Calvin::LOG.info "ContextRetriever: ===== END RULES ====="
    end

    def format_rules(chunks)
      lines = ["## Active rules", ""]
      chunks.each do |chunk|
        content = chunk["content"].to_s.strip
        lines << "- #{content}"
      end
      lines.join("\n")
    end

    def rag_config(key)
      Calvin::CONFIG.dig(:rag, key) || Calvin::CONFIG.dig(:rag, key.to_s)
    end
  end
end
