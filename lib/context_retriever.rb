# frozen_string_literal: true
# ContextRetriever — recupera regole rilevanti da Supabase prima del ReActLoop.
#
# Interfaccia pubblica:
#   ContextRetriever.call_for_explore(issue)      => RetrievalResult
#   ContextRetriever.call_for_implement(file_plan) => RetrievalResult
#   ContextRetriever.call_for_test(source_path)   => RetrievalResult
#
# RetrievalResult = Data.define(:rules, :context, :chunks)
#   .rules   => String formattata con le regole attive, o nil
#   .context => nil (predisposto per source_type futuri)
#   .chunks  => Array di hash raw { "content", "source_path", "similarity" } o []
#
# Se SUPABASE_URL o SUPABASE_SERVICE_KEY non sono presenti => .rules = nil silenzioso.
# Se Mistral o Supabase sono down => .rules = nil silenzioso.

require "net/http"
require "json"

module Calvin
  RetrievalResult = Data.define(:rules, :context, :chunks)

  class ContextRetriever
    EMBED_URL  = URI("https://api.mistral.ai/v1/embeddings")
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20

    TEST_SOURCE_TYPES = %w[fixture test_helper rule].freeze

    LAYER_TOKENS = %w[
      service controller migration job serializer
      contract query presenter policy mailer
    ].freeze

    # --- Fase pubblica API ---------------------------------------------------

    def self.call_for_explore(issue)
      new.call_with_query(build_issue_query(issue),
                          top_k: config_top_k(:explore, default: 10), phase: "explore")
    end

    def self.call(issue) = call_for_explore(issue) # alias retrocompatibile

    def self.call_for_implement(file_plan)
      paths = (Array(file_plan[:modify]) + Array(file_plan[:create])).uniq
      if paths.empty?
        Calvin::LOG.info "ContextRetriever[implement]: nessun path nel file_plan — skip"
        return RetrievalResult.new(rules: nil, context: nil, chunks: [])
      end
      new.call_with_query(build_file_plan_query(paths),
                          top_k: config_top_k(:implement, default: 20), phase: "implement")
    end

    def self.call_for_test(source_path)
      Calvin::LOG.info "ContextRetriever[test]: query=#{build_test_query(source_path).inspect}, source_types=#{TEST_SOURCE_TYPES}"
      new.call_with_query(build_test_query(source_path),
                          top_k: config_top_k(:test, default: 15), phase: "test",
                          source_types: TEST_SOURCE_TYPES)
    end

    # --- Costruzione query ---------------------------------------------------

    def self.build_issue_query(issue)
      body_limit = Calvin::CONFIG.dig(:rag, :query_body_limit) || 2000
      "#{issue.title} #{issue.body.to_s[0..body_limit]}".strip
    end

    def self.build_file_plan_query(paths)
      seen_layers = Set.new
      tokens = paths.flat_map do |path|
        layer = extract_layer(path)
        name  = extract_name(path)
        [].tap do |parts|
          parts << layer if layer && seen_layers.add?(layer)
          parts << name  if name && !name.empty?
        end
      end
      query = tokens.first(12).join(" ")
      Calvin::LOG.info "ContextRetriever[implement]: query costruita da #{paths.size} path = #{query.inspect}"
      query
    end

    def self.build_test_query(source_path)
      layer = extract_layer(source_path.to_s) || "code"
      name  = extract_name(source_path.to_s)
      "test #{layer} #{name}".strip
    end

    def self.extract_layer(path)
      segments = path.to_s.split("/")
      segments.find { |s| LAYER_TOKENS.any? { |l| s.include?(l) } }
              &.then { |s| LAYER_TOKENS.find { |l| s.include?(l) } }
    end

    def self.extract_name(path)
      File.basename(path.to_s, ".*")
          .gsub(/_?(#{LAYER_TOKENS.join('|')})$/, "")
          .gsub(/\A\d+_/, "")
          .tr("_", " ")
          .strip
    end

    def self.config_top_k(phase, default:)
      Calvin::CONFIG.dig(:rag, :"top_k_#{phase}") || default
    end

    # --- Pipeline embed + search + filter ------------------------------------

    def call_with_query(query, top_k:, phase: "unknown", source_types: nil)
      unless supabase_configured?
        Calvin::LOG.info "ContextRetriever[#{phase}]: Supabase non configurato — skip"
        return RetrievalResult.new(rules: nil, context: nil, chunks: [])
      end

      Calvin::LOG.info "ContextRetriever[#{phase}]: query=#{query[0..120]}..., top_k=#{top_k}"

      embedding = embed(query)
      rpc_path  = source_types ? "/rest/v1/rpc/calvin_context_search" : "/rest/v1/rpc/calvin_rules_search"
      payload   = { query_embedding: embedding, match_count: top_k, target_repo: target_repo }
      payload[:source_types] = source_types if source_types

      raw    = post_rpc(rpc_path, payload, phase)
      chunks = filter_by_threshold(raw, phase)

      if chunks.empty?
        Calvin::LOG.info "ContextRetriever[#{phase}]: nessun chunk trovato (#{raw.size} recuperati, tutti sotto soglia)"
        return RetrievalResult.new(rules: nil, context: nil, chunks: [])
      end

      Calvin::LOG.info "ContextRetriever[#{phase}]: #{chunks.size}/#{raw.size} chunk accettati (threshold=#{similarity_threshold(phase)})"
      log_chunks(chunks, phase)
      RetrievalResult.new(rules: format_rules(chunks), context: nil, chunks: chunks)
    rescue => e
      Calvin::LOG.warn "ContextRetriever[#{phase}]: fallback silenzioso — #{e.class}: #{e.message}"
      Calvin::LOG.warn e.backtrace.first(3).join(" | ") if e.backtrace
      RetrievalResult.new(rules: nil, context: nil, chunks: [])
    end

    private

    def supabase_configured?
      ENV["SUPABASE_URL"] && ENV["SUPABASE_SERVICE_KEY"]
    end

    def target_repo
      Calvin::CONFIG.dig(:rag, :target_repo) or
        raise "rag.target_repo non configurato in config/calvin.yml"
    end

    def similarity_threshold(phase)
      Calvin::CONFIG.dig(:rag, :similarity_threshold, phase.to_sym) ||
        Calvin::CONFIG.dig(:rag, :similarity_threshold) ||
        0.60
    end

    def filter_by_threshold(chunks, phase)
      threshold = similarity_threshold(phase)
      accepted, below = chunks.partition { |c| c["similarity"].to_f >= threshold }
      if below.any?
        Calvin::LOG.info "ContextRetriever[#{phase}]: #{below.size} chunk filtrati sotto soglia #{threshold}:"
        below.each { |c| Calvin::LOG.info "  skip #{c['source_path']} sim=#{c['similarity'].to_f.round(3)}" }
      end
      accepted
    end

    # Unico metodo HTTP — usato sia per rules che per context search.
    def post_rpc(path, payload, phase = "rpc")
      url     = URI("#{ENV['SUPABASE_URL']}#{path}")
      api_key = ENV.fetch("SUPABASE_SERVICE_KEY")

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Post.new(url)
      req["apikey"]          = api_key
      req["Authorization"]   = "Bearer #{api_key}"
      req["Content-Type"]    = "application/json"
      req["Accept-Encoding"] = "identity"
      req.body = payload.to_json

      resp = http.request(req)
      Calvin::LOG.info "ContextRetriever[#{phase}]: HTTP #{resp.code}, body_size=#{resp.body.bytesize}"
      raise "Supabase RPC HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    end

    def embed(query)
      api_key = ENV.fetch("MISTRAL_API_KEY")
      payload = { model: embed_model, input: [query] }.to_json

      http = Net::HTTP.new(EMBED_URL.host, EMBED_URL.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Post.new(EMBED_URL)
      req["Authorization"]   = "Bearer #{api_key}"
      req["Content-Type"]    = "application/json"
      req["Accept-Encoding"] = "identity"
      req.body = payload

      resp = http.request(req)
      Calvin::LOG.info "ContextRetriever[embed]: HTTP #{resp.code}"
      raise "Mistral embed HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body).dig("data", 0, "embedding") or raise "embedding non trovato"
    end

    def embed_model
      Calvin::CONFIG.dig(:rag, :embed_model) || "mistral-embed"
    end

    def format_rules(chunks)
      chunks.map.with_index(1) do |c, i|
        "#{i}. [#{c['source_path']} sim=#{c['similarity'].to_f.round(3)}]\n#{c['content']}"
      end.join("\n\n")
    end

    def log_chunks(chunks, phase)
      chunks.each { |c| Calvin::LOG.info "ContextRetriever[#{phase}]:   accept #{c['source_path']} sim=#{c['similarity'].to_f.round(3)}" }
    end
  end
end
