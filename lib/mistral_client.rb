# frozen_string_literal: true
# Client per Mistral / Codestral API.
# Modello: codestral-latest per tutti i flussi (comment + aider).
#
# .complete(prompt)  → String (markdown)

require "net/http"
require "json"

module Calvin
  class MistralClient
    API_URL       = URI("https://api.mistral.ai/v1/chat/completions")
    DEFAULT_MODEL = ENV.fetch("CALVIN_MODEL", "codestral-latest")

    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 180

    def initialize(api_key: ENV.fetch("MISTRAL_API_KEY"))
      @api_key = api_key
    end

    # Risposta markdown — usata dal flusso commento (label: agent)
    def complete(prompt)
      call(prompt, model: DEFAULT_MODEL)
    end

    private

    def call(prompt, model:)
      http              = Net::HTTP.new(API_URL.host, API_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      messages = [{ role: "user", content: prompt }]

      req                  = Net::HTTP::Post.new(API_URL)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      req.body             = { model: model, messages: messages }.to_json

      resp = http.request(req)
      raise "Mistral error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body).dig("choices", 0, "message", "content")
    end
  end
end
