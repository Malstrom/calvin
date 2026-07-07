# frozen_string_literal: true
# SupabaseStore — upsert chunk su Supabase via REST API.
#
# Ingestion::SupabaseStore.new.upsert(repo:, source_type:, source_path:, content:, embedding:)
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
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                       = Net::HTTP::Post.new(uri)
      req["Content-Type"]       = "application/json"
      req["Authorization"]      = "Bearer #{@key}"
      req["apikey"]             = @key
      req["Prefer"]             = "resolution=merge-duplicates"

      req.body = {
        repo:        repo,
        source_type: source_type,
        source_path: source_path,
        content:     content,
        embedding:   "[#{embedding.join(",")}]",
        updated_at:  Time.now.utc.iso8601
      }.to_json

      resp = http.request(req)
      raise "Supabase upsert error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      true
    end
  end
end
