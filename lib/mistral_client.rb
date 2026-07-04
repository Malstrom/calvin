# frozen_string_literal: true
# Client per Mistral / Codestral API.
# Modello: codestral-latest per tutti i flussi.
#
# .complete(prompt)  → { content: String, usage: Hash }
#   usage: { "prompt_tokens" => Int, "completion_tokens" => Int, "total_tokens" => Int }

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

    # Returns { content: String, usage: Hash }
    def complete(prompt)
      call(prompt, model: DEFAULT_MODEL)
    end

    private

    def call(prompt, model:)
      http              = Net::HTTP.new(API_URL.host, API_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                  = Net::HTTP::Post.new(API_URL)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      req.body             = { model: model, messages: [{ role: "user", content: prompt }] }.to_json

      resp = http.request(req)
      raise "Mistral error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      body = JSON.parse(resp.body)
      {
        content: body.dig("choices", 0, "message", "content"),
        usage:   body["usage"]
      }
    end
  end
end
