# frozen_string_literal: true
# Client per Mistral / Codestral API.
#
# .complete(prompt, temperature:)            → { content: String, usage: Hash }  — singola chiamata
# .complete_messages(messages, temperature:) → { content: String, usage: Hash }  — multi-turno (ReAct)
#
# usage: { "prompt_tokens" => Int, "completion_tokens" => Int, "total_tokens" => Int }
#
# temperature e max_tokens vengono letti da Calvin::CONFIG[:sampling].
# Passare temperature: esplicitamente sovrascrive il default.
# open_timeout e read_timeout letti da Calvin::CONFIG[:mistral].

require "net/http"
require "json"

module Calvin
  class MistralClient
    API_URL       = URI("https://api.mistral.ai/v1/chat/completions")
    DEFAULT_MODEL = ENV.fetch("CALVIN_MODEL", "codestral-latest")

    def initialize(api_key: ENV.fetch("MISTRAL_API_KEY"))
      @api_key      = api_key
      @sampling     = Calvin::CONFIG.dig(:sampling) || {}
      @max_tokens   = @sampling[:max_tokens] || 8192
      mistral_cfg   = Calvin::CONFIG.dig(:mistral) || {}
      @open_timeout = (mistral_cfg[:open_timeout] || 15).to_i
      @read_timeout = (mistral_cfg[:read_timeout] || 180).to_i
    end

    # Singola chiamata — prompt testuale, usato da ImplementFlow e CiFixFlow
    def complete(prompt, temperature: default_temperature(:implement))
      complete_messages([{ role: "user", content: prompt }], temperature: temperature)
    end

    # Multi-turno — array di messages, usato dal ReAct loop (explore phase)
    # messages: [{ role: "user"|"assistant"|"tool", content: String }, ...]
    def complete_messages(messages, temperature: default_temperature(:implement))
      call(messages, model: DEFAULT_MODEL, temperature: temperature)
    end

    private

    def default_temperature(phase)
      @sampling.dig(:temperature, phase) ||
        @sampling.dig(:temperature, phase.to_s) ||
        0.0
    end

    def call(messages, model:, temperature:)
      http              = Net::HTTP.new(API_URL.host, API_URL.port)
      http.use_ssl      = true
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      req                  = Net::HTTP::Post.new(API_URL)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"
      req.body             = {
        model:       model,
        messages:    messages,
        temperature: temperature,
        max_tokens:  @max_tokens
      }.to_json

      resp = http.request(req)
      raise "Mistral error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      body = JSON.parse(resp.body)
      {
        content:     body.dig("choices", 0, "message", "content"),
        usage:       body["usage"],
        temperature: temperature
      }
    end
  end
end
