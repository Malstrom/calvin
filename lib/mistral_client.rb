# frozen_string_literal: true
# Client per Mistral / Codestral API.
#
# .complete(prompt)           → { content: String, usage: Hash }  — singola chiamata
# .complete_messages(messages) → { content: String, usage: Hash }  — multi-turno (ReAct)
#
# usage: { "prompt_tokens" => Int, "completion_tokens" => Int, "total_tokens" => Int }

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

    # Singola chiamata — prompt testuale, usato da ImplementFlow e CiFixFlow
    def complete(prompt)
      complete_messages([{ role: "user", content: prompt }])
    end

    # Multi-turno — array di messages, usato dal futuro ReAct loop (calvin-auto)
    # messages: [{ role: "user"|"assistant"|"tool", content: String }, ...]
    def complete_messages(messages)
      call(messages, model: DEFAULT_MODEL)
    end

    private

    def call(messages, model:)
      http              = Net::HTTP.new(API_URL.host, API_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                  = Net::HTTP::Post.new(API_URL)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      req.body             = { model: model, messages: messages }.to_json

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
