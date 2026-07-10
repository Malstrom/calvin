# frozen_string_literal: true
# SupabaseStore — upsert e similarity search chunk su Supabase via REST API.
#
# Ingestion::SupabaseStore.new.upsert(repo:, source_type:, source_path:, content:, embedding:)
# Ingestion::SupabaseStore.new.similar_to(embedding, repo:, threshold: 0.92, limit: 1)
# => [{ "source_path" => "rule/38/2", "content" => "...", "similarity" => 0.9431 }]
#
# Usa l'header "Prefer: resolution=merge-duplicates" per fare upsert automatico
# sul constraint unique(repo, source_path) — idempotente.
# L'embedding viene serializzato come stringa "[f1,f2,...]" compatibile con pgvector.

require "net/http"
require "json"
require "uri"

module Ingestion
  class SupabaseStore
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    def initialize(
      url: ENV.fetch("SUPABASE_URL"),
      key: ENV.fetch("SUPABASE_SERVICE_KEY")
    )
      @url = url.chomp("/")
      @key = key
    end

    def upsert(repo:, source_type:, source_path:, content:, embedding:)
      uri  = URI("#{@url}/rest/v1/calvin_chunks")
      http = build_http(uri)

      req              = Net::HTTP::Post.new(uri)
      set_headers(req)
      req["Prefer"] = "resolution=merge-duplicates"

      req.body = {
        repo:        repo,
        source_type: source_type,
        source_path: source_path,
        content:     content,
        embedding:   "[#{embedding.join(",")}]",
        updated_at:  Time.now.utc.iso8601
      }.to_json

      resp = http.request(req)
      body = resp.body.to_s.force_encoding("UTF-8")
      raise "Supabase upsert error: #{resp.code} #{body}" unless resp.is_a?(Net::HTTPSuccess)

      true
    end

    # Cerca chunk semanticamente simili a embedding.
    # Usa la RPC calvin_rules_search definita nel DB Supabase.
    # Ritorna array di hash con source_path, content, similarity.
    def similar_to(embedding, repo:, threshold: 0.92, limit: 1)
      uri  = URI("#{@url}/rest/v1/rpc/calvin_rules_search")
      http = build_http(uri)

      req = Net::HTTP::Post.new(uri)
      set_headers(req)

      req.body = {
        query_embedding: embedding,
        target_repo:     repo,
        match_count:     limit
      }.to_json

      resp = http.request(req)
      body = resp.body.to_s.force_encoding("UTF-8")
      raise "Supabase similarity error: #{resp.code} #{body}" unless resp.is_a?(Net::HTTPSuccess)

      results = JSON.parse(body)
      results.select { |r| r["similarity"].to_f >= threshold }
    end

    private

    def build_http(uri)
      http              = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http
    end

    def set_headers(req)
      req["Content-Type"]    = "application/json"
      req["Authorization"]   = "Bearer #{@key}"
      req["apikey"]          = @key
      req["Accept-Encoding"] = "identity"
    end
  end
end
