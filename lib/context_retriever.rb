# frozen_string_literal: true
# ContextRetriever — recupera chunk rilevanti da Supabase prima del ReActLoop.
#
# .call(issue) => String (formatted context) | nil (graceful fallback)
#
# Flusso:
#   1. Costruisce query testuale da issue.title + issue.body (primi 500 char)
#   2. Chiama mistral-embed per ottenere l'embedding della query
#   3. Chiama RPC calvin_similarity_search su Supabase con top_k=5
#   4. Formatta i chunk come sezione ## Retrieved context
#
# Se SUPABASE_URL o SUPABASE_SERVICE_KEY non sono presenti → nil silenzioso.
# Se Mistral o Supabase sono down → nil silenzioso.

require "net/http"
require "json"

module Calvin
  class ContextRetriever
    TOP_K          = 5
    EMBED_URL      = URI("https://api.mistral.ai/v1/embeddings")
    EMBED_MODEL    = "mistral-embed"
    OPEN_TIMEOUT   = 10
    READ_TIMEOUT   = 20

    def self.call(issue)
      new.call(issue)
    end

    def call(issue)
      return nil unless supabase_configured?

      query     = build_query(issue)
      Calvin::LOG.info "ContextRetriever: query = #{query[0..120]}..."

      embedding = embed(query)
      chunks    = search(embedding)

      if chunks.empty?
        Calvin::LOG.info "ContextRetriever: nessun chunk trovato"
        return nil
      end

      Calvin::LOG.info "ContextRetriever: #{chunks.size} chunk(s) recuperati"
      log_chunks(chunks)
      format_chunks(chunks)
    rescue => e
      Calvin::LOG.warn "ContextRetriever: fallback silenzioso (#{e.message})"
      nil
    end

    private

    def supabase_configured?
      ENV["SUPABASE_URL"] && ENV["SUPABASE_SERVICE_KEY"]
    end

    def build_query(issue)
      body_excerpt = issue.body.to_s[0..500]
      "#{issue.title} #{body_excerpt}".strip
    end

    def embed(text)
      http              = Net::HTTP.new(EMBED_URL.host, EMBED_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                  = Net::HTTP::Post.new(EMBED_URL)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{ENV.fetch('MISTRAL_API_KEY')}"
      req.body             = { model: EMBED_MODEL, input: [text] }.to_json

      resp = http.request(req)
      raise "Mistral embed error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body).dig("data", 0, "embedding")
    end

    def search(embedding)
      repo = Calvin::REPO
      url  = URI("#{ENV['SUPABASE_URL']}/rest/v1/rpc/calvin_similarity_search")

      http              = Net::HTTP.new(url.host, url.port)
      http.use_ssl      = url.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                   = Net::HTTP::Post.new(url)
      req["Content-Type"]   = "application/json"
      req["apikey"]         = ENV["SUPABASE_SERVICE_KEY"]
      req["Authorization"]  = "Bearer #{ENV['SUPABASE_SERVICE_KEY']}"
      req.body              = { query_embedding: embedding, target_repo: repo, match_count: TOP_K }.to_json

      resp = http.request(req)
      raise "Supabase RPC error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end

    def log_chunks(chunks)
      Calvin::LOG.info "ContextRetriever: ===== CHUNK RETRIEVED ====="
      chunks.each_with_index do |chunk, i|
        source_type = chunk["source_type"] || "doc"
        source_path = chunk["source_path"] || "unknown"
        similarity  = chunk["similarity"] ? format("%.4f", chunk["similarity"]) : "n/a"
        content     = chunk["content"].to_s.strip
        Calvin::LOG.info "ContextRetriever: [#{i + 1}/#{chunks.size}] #{source_type}:#{source_path} (similarity=#{similarity})"
        Calvin::LOG.info "ContextRetriever: #{content}"
        Calvin::LOG.info "ContextRetriever: -----"
      end
      Calvin::LOG.info "ContextRetriever: ===== END CHUNKS ====="
    end

    def format_chunks(chunks)
      lines = ["## Retrieved context", ""]
      chunks.each do |chunk|
        source_type = chunk["source_type"] || "doc"
        source_path = chunk["source_path"] || "unknown"
        content     = chunk["content"].to_s.strip
        lines << "### [#{source_type}] #{source_path}"
        lines << content
        lines << ""
      end
      lines.join("\n")
    end
  end
end
