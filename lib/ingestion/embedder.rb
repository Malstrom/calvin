# frozen_string_literal: true
# Embedder — genera embedding tramite mistral-embed.
#
# Ingestion::Embedder.new.embed("testo") → Array<Float> (1024 dimensioni)
#
# Riusa lo stesso pattern HTTP di MistralClient ma punta a /v1/embeddings.
# Batch singolo: una stringa per chiamata (semplice e senza limiti di rate complessi).

require "net/http"
require "json"

module Ingestion
  class Embedder
    API_URL      = URI("https://api.mistral.ai/v1/embeddings")
    MODEL        = "mistral-embed"
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 30

    def initialize(api_key: ENV.fetch("MISTRAL_API_KEY"))
      @api_key = api_key
    end

    # Ritorna Array<Float> di 1024 elementi
    def embed(text)
      http              = Net::HTTP.new(API_URL.host, API_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                  = Net::HTTP::Post.new(API_URL)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      req.body             = { model: MODEL, input: [text] }.to_json

      resp = http.request(req)
      raise "Mistral embed error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body).dig("data", 0, "embedding")
    end
  end
end
