# frozen_string_literal: true
# Client per Mistral / Codestral API.
#
# .complete(prompt, temperature:)                        → { content: String, usage: Hash }
# .complete_messages(messages, temperature:, cache_key:) → { content: String, usage: Hash }
#
# usage: { "prompt_tokens" => Int, "completion_tokens" => Int, "total_tokens" => Int }
#
# cache_key: stringa opzionale. Se presente, viene passata come prompt_cache_key
# all'API Mistral per attivare il prefix caching sul prefisso condiviso tra i turni.
# I token cachati vengono addebitati al 10% del prezzo normale.
# Usare solo durante la fase explore (multi-turn) — non serve per implement.
#
# temperature e max_tokens vengono letti da Calvin::CONFIG[:sampling].
# Passare temperature: esplicitamente sovrascrive il default.

require "net/http"
require "json"

module Calvin
  class MistralClient
    # Tutti i valori letti da CONFIG — nessun valore hardcodato.
    API_URL      = URI(Calvin::CONFIG.dig(:mistral, :api_url) || "https://api.mistral.ai/v1/chat/completions")
    OPEN_TIMEOUT = Calvin::CONFIG.dig(:http, :open_timeout) || 15
    READ_TIMEOUT = Calvin::CONFIG.dig(:http, :read_timeout) || 180
    DEFAULT_MODEL = ENV.fetch("CALVIN_MODEL", Calvin::CONFIG.dig(:model, :default) || "codestral-latest")

    def initialize(api_key: ENV.fetch("MISTRAL_API_KEY"))
      @api_key    = api_key
      @sampling   = Calvin::CONFIG.dig(:sampling) || {}
      @max_tokens = @sampling[:max_tokens] || 8192
    end

    # Singola chiamata — prompt testuale
    def complete(prompt, temperature: default_temperature(:implement))
      complete_messages([{ role: "user", content: prompt }], temperature: temperature)
    end

    # Multi-turno — array di messages, usato dal ReAct loop (explore phase)
    # messages:  [{ role: "user"|"assistant"|"tool", content: String }, ...]
    # cache_key: String opzionale — attiva prompt caching sul prefisso condiviso
    def complete_messages(messages, temperature: default_temperature(:implement), cache_key: nil)
      call(messages, model: DEFAULT_MODEL, temperature: temperature, cache_key: cache_key)
    end

    private

    def default_temperature(phase)
      @sampling.dig(:temperature, phase) ||
        @sampling.dig(:temperature, phase.to_s) ||
        0.0
    end

    def call(messages, model:, temperature:, cache_key: nil)
      http              = Net::HTTP.new(API_URL.host, API_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req                  = Net::HTTP::Post.new(API_URL)
      req["Content-Type"]  = "application/json"
      req["Authorization"] = "Bearer #{@api_key}"

      body = {
        model:       model,
        messages:    messages,
        temperature: temperature,
        max_tokens:  @max_tokens
      }
      body[:prompt_cache_key] = cache_key if cache_key

      req.body = body.to_json

      resp = http.request(req)
      raise "Mistral error: #{resp.code} #{resp.body}" unless resp.is_a?(Net::HTTPSuccess)

      body = JSON.parse(resp.body)
      usage         = body["usage"]
      finish_reason = body.dig("choices", 0, "finish_reason")

      if cache_key && usage
        cached = usage.dig("prompt_tokens_details", "cached_tokens").to_i
        Calvin::LOG.info "MistralClient: cached_tokens=#{cached} / #{usage['prompt_tokens']} prompt" if cached > 0
      end

      Calvin::LOG.warn "MistralClient: finish_reason=#{finish_reason} (possible truncation)" if finish_reason != "stop"

      {
        content:       body.dig("choices", 0, "message", "content"),
        usage:         usage,
        temperature:   temperature,
        finish_reason: finish_reason
      }
    end
  end
end
