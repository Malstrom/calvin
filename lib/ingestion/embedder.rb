# frozen_string_literal: true
# Embedder — genera embedding tramite mistral-embed.
#
# Ingestion::Embedder.new.embed("testo") → Array<Float> (1024 dimensioni)

require "net/http"
require "json"

module Ingestion
  class Embedder
    API_URL      = URI("https://api.mistral.ai/v1/embeddings")
    MODEL        = "mistral-embed"
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 30
    MAX_RETRIES  = 5
    BASE_DELAY   = 2.0  # seconds, doubles on each retry

    def initialize(api_key: ENV.fetch("MISTRAL_API_KEY"))
      @api_key = api_key
    end

    def embed(text)
      retries = 0
      delay   = BASE_DELAY

      begin
        http              = Net::HTTP.new(API_URL.host, API_URL.port)
        http.use_ssl      = true
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT

        req                  = Net::HTTP::Post.new(API_URL)
        req["Content-Type"]  = "application/json"
        req["Authorization"] = "Bearer #{@api_key}"
        req.body             = { model: MODEL, input: [text] }.to_json

        resp = http.request(req)

        if resp.code == "429" && retries < MAX_RETRIES
          retries += 1
          puts "[embedder] 429 rate limit, retry #{retries}/#{MAX_RETRIES} in #{delay}s..."
          sleep delay
          delay *= 2
          retry
        end

        raise "Mistral embed error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

        JSON.parse(resp.body).dig("data", 0, "embedding")
      end
    end
  end
end
