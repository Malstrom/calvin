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
#   1. Costruisce query testuale da issue.title + issue.body
#      (lunghezza body configurabile via rag.query_body_limit, default 2000)
#   2. Chiama mistral-embed per ottenere l'embedding della query (1024 dim)
#   3. Chiama RPC calvin_rules_search su Supabase (top_k dal CONFIG o nessun limite)
#   4. Filtra i chunk con similarity < rag.similarity_threshold (default 0.60)
#   5. Ritorna RetrievalResult con regole formattate
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
      raw       = search_rules(embedding)
      chunks    = filter_by_threshold(raw)

      if chunks.empty?
        Calvin::LOG.info "ContextRetriever: nessuna regola trovata (#{raw.size} recuperate, tutte sotto soglia)"
        return RetrievalResult.new(rules: nil, context: nil)
      end

      Calvin::LOG.info "ContextRetriever: #{chunks.size}/#{raw.size} regola/e accettate (threshold=#{similarity_threshold})"
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
      body_excerpt = issue.body.to_s[0..query_body_limit]
      "#{issue.title} #{body_excerpt}".strip
    end

    def filter_by_threshold(chunks)
      threshold = similarity_threshold
      below     = chunks.reject { |c| c["similarity"].to_f >= threshold }
      accepted  = chunks.select { |c| c["similarity"].to_f >= threshold }

      if below.any?
        Calvin::LOG.info "ContextRetriever: #{below.size} chunk filtrati sotto soglia #{threshold}:"
        below.each do |c|
          Calvin::LOG.info "ContextRetriever:   skip #{c['source_path']} (similarity=#{format('%.4f', c['similarity'].to_f)})"
        end
      end

      accepted
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

    def query_body_limit
      rag_config(:query_body_limit)&.to_i || 2000
    end

    def similarity_threshold
      rag_config(:similarity_threshold)&.to_f || 0.60
    end

    def rag_config(key)
      Calvin::CONFIG.dig(:rag, key) || Calvin::CONFIG.dig(:rag, key.to_s)
    end
  end
end
