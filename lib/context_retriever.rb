# frozen_string_literal: true
# ContextRetriever — recupera regole rilevanti da Supabase prima del ReActLoop.
#
# Interfaccia pubblica:
#   ContextRetriever.call_for_explore(issue)      => RetrievalResult
#   ContextRetriever.call_for_implement(file_plan) => RetrievalResult
#   ContextRetriever.call_for_test(source_path)   => RetrievalResult
#
# RetrievalResult = Data.define(:rules, :context, :chunks)
#   .rules   => String formattata con le regole attive, o nil se nessuna trovata
#   .context => nil (predisposto per source_type futuri)
#   .chunks  => Array di hash raw { "content", "source_path", "similarity" } o []
#
# Flusso explore:
#   1. Costruisce query da issue.title + issue.body (limit: rag.query_body_limit, default 2000)
#   2. Chiama mistral-embed per l'embedding (1024 dim)
#   3. Chiama RPC calvin_rules_search su Supabase (top_k: rag.top_k_explore)
#   4. Filtra chunk con similarity < rag.similarity_threshold.explore (default 0.60)
#   5. Ritorna RetrievalResult con regole formattate e chunks raw
#
# Flusso implement:
#   1. Costruisce query dai path del file_plan (modify + create) tramite path_to_query
#      es. "app/services/foo_service.rb" => "service foo"
#   2. Stessa pipeline embed + search con top_k: rag.top_k_implement
#   3. Soglia: rag.similarity_threshold.implement (default 0.52)
#
# Flusso test:
#   1. Costruisce query da source_path: "test {layer} {name}"
#      es. "app/services/magic_link_service.rb" => "test service magic link"
#   2. Chiama mistral-embed per l'embedding
#   3. Chiama RPC calvin_context_search con source_types=['fixture','test_helper','rule']
#      (RPC diversa da calvin_rules_search — filtra per tipo, non solo 'rule')
#   4. Soglia: rag.similarity_threshold.test (default 0.55)
#   5. top_k: rag.top_k_test (default 15)
#
# Se SUPABASE_URL o SUPABASE_SERVICE_KEY non sono presenti => .rules = nil silenzioso.
# Se Mistral o Supabase sono down => .rules = nil silenzioso.

require "net/http"
require "json"

module Calvin
  RetrievalResult = Data.define(:rules, :context, :chunks)

  class ContextRetriever
    EMBED_URL    = URI("https://api.mistral.ai/v1/embeddings")
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 20

    TEST_SOURCE_TYPES = %w[fixture test_helper rule].freeze

    # Layer tokens estratti dal path per costruire query semantiche dai file.
    # Ordine: più specifici prima, fallback generico alla fine.
    LAYER_TOKENS = %w[
      service controller migration job serializer
      contract query presenter policy mailer
    ].freeze

    # ---------------------------------------------------------------------------
    # Fase 1 — Explore
    # Query: title + body dell'issue (contesto dominio ampio)
    # top_k: rag.top_k_explore (default 10 — tenere basso per ridurre rumore nel system prompt)
    # ---------------------------------------------------------------------------
    def self.call_for_explore(issue)
      top_k = Calvin::CONFIG.dig(:rag, :top_k_explore) ||
              Calvin::CONFIG.dig(:rag, :top_k_rules)   ||  # retrocompatibilità
              10
      new.call_with_query(build_issue_query(issue), top_k: top_k, phase: "explore")
    end

    # Alias retrocompatibile — rimosso quando tutti i caller sono aggiornati.
    def self.call(issue)
      call_for_explore(issue)
    end

    # ---------------------------------------------------------------------------
    # Fase 2 — Implement
    # Query: costruita dai path del file_plan (modify + create)
    # top_k: rag.top_k_implement (default 20 — query più precisa, più regole utili)
    # ---------------------------------------------------------------------------
    def self.call_for_implement(file_plan)
      top_k = Calvin::CONFIG.dig(:rag, :top_k_implement) || 20
      paths = (Array(file_plan[:modify]) + Array(file_plan[:create])).uniq

      if paths.empty?
        Calvin::LOG.info "ContextRetriever[implement]: nessun path nel file_plan — skip"
        return RetrievalResult.new(rules: nil, context: nil, chunks: [])
      end

      query = build_file_plan_query(paths)
      new.call_with_query(query, top_k: top_k, phase: "implement")
    end

    # ---------------------------------------------------------------------------
    # Fase 3 — Test
    # Query: "test {layer} {name}" costruita dal source_path
    # RPC: calvin_context_search con source_types=['fixture','test_helper','rule']
    # top_k: rag.top_k_test (default 15)
    # soglia: rag.similarity_threshold.test (default 0.55)
    # ---------------------------------------------------------------------------
    def self.call_for_test(source_path)
      top_k = Calvin::CONFIG.dig(:rag, :top_k_test) || 15
      query = build_test_query(source_path)
      Calvin::LOG.info "ContextRetriever[test]: query = #{query.inspect}, source_types=#{TEST_SOURCE_TYPES}"
      new.call_with_query(query, top_k: top_k, phase: "test", source_types: TEST_SOURCE_TYPES)
    end

    # ---------------------------------------------------------------------------
    # Costruzione query
    # ---------------------------------------------------------------------------

    def self.build_issue_query(issue)
      body_limit   = Calvin::CONFIG.dig(:rag, :query_body_limit) || 2000
      body_excerpt = issue.body.to_s[0..body_limit]
      "#{issue.title} #{body_excerpt}".strip
    end

    # Converte una lista di path in una query testuale per embedding.
    # Estrae layer (service, controller...) e nome semantico da ogni path.
    # Deduplicazione per layer: un solo token per tipo di layer.
    # es. ["app/services/foo_service.rb", "app/services/bar_service.rb",
    #       "app/controllers/api/v1/foo_controller.rb"]
    #     => "service foo bar controller foo"
    def self.build_file_plan_query(paths)
      seen_layers = Set.new
      tokens = paths.flat_map do |path|
        layer = extract_layer(path)
        name  = extract_name(path)
        parts = []
        # Includi il layer token solo la prima volta che compare
        parts << layer if layer && seen_layers.add?(layer)
        parts << name  if name && !name.empty?
        parts
      end

      query = tokens.first(12).join(" ")
      Calvin::LOG.info "ContextRetriever[implement]: query costruita da #{paths.size} path = #{query.inspect}"
      query
    end

    # "test service magic link" — prefisso "test" sposta l'embedding verso
    # fixture e test_helper oltre che verso le regole di quel layer.
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
          .gsub(/\A\d+_/, "")   # rimuovi prefisso timestamp migration
          .tr("_", " ")
          .strip
    end

    # ---------------------------------------------------------------------------
    # Pipeline comune: embed + search + filter
    # source_types: se nil usa calvin_rules_search (comportamento storico)
    #               se Array usa calvin_context_search con filtro per tipo
    # ---------------------------------------------------------------------------

    def call_with_query(query, top_k:, phase: "unknown", source_types: nil)
      unless supabase_configured?
        Calvin::LOG.info "ContextRetriever[#{phase}]: Supabase non configurato — skip"
        return RetrievalResult.new(rules: nil, context: nil, chunks: [])
      end

      Calvin::LOG.info "ContextRetriever[#{phase}]: query = #{query[0..120]}..."
      Calvin::LOG.info "ContextRetriever[#{phase}]: query_length = #{query.length} chars, top_k = #{top_k}"

      embedding = embed(query)
      raw       = source_types ? search_context(embedding, top_k, source_types) : search_rules(embedding, top_k)
      chunks    = filter_by_threshold(raw, phase)

      if chunks.empty?
        Calvin::LOG.info "ContextRetriever[#{phase}]: nessun chunk trovato (#{raw.size} recuperati, tutti sotto soglia)"
        return RetrievalResult.new(rules: nil, context: nil, chunks: [])
      end

      Calvin::LOG.info "ContextRetriever[#{phase}]: #{chunks.size}/#{raw.size} chunk accettati (threshold=#{similarity_threshold(phase)})"
      log_chunks(chunks, phase)

      RetrievalResult.new(rules: format_rules(chunks), context: nil, chunks: chunks)
    rescue => e
      Calvin::LOG.warn "ContextRetriever[#{phase}]: fallback silenzioso — #{e.class}: #{e.message}"
      Calvin::LOG.warn "ContextRetriever[#{phase}]: #{e.backtrace.first(3).join(' | ')}" if e.backtrace
      RetrievalResult.new(rules: nil, context: nil, chunks: [])
    end

    private

    def supabase_configured?
      ENV["SUPABASE_URL"] && ENV["SUPABASE_SERVICE_KEY"]
    end

    def filter_by_threshold(chunks, phase = "unknown")
      threshold = similarity_threshold(phase)
      below     = chunks.reject { |c| c["similarity"].to_f >= threshold }
      accepted  = chunks.select { |c| c["similarity"].to_f >= threshold }

      if below.any?
        Calvin::LOG.info "ContextRetriever[#{phase}]: #{below.size} chunk filtrati sotto soglia #{threshold}:"
        below.each do |c|
          Calvin::LOG.info "ContextRetriever[#{phase}]:   skip #{c['source_path']} sim=#{c['similarity'].to_f.round(3)}"
        end
      end

      accepted
    end

    # Legge la soglia per la fase corrente dalla sottostruttura rag.similarity_threshold.
    # Fallback 1: chiave flat rag.similarity_threshold (retrocompatibilità).
    # Fallback 2: 0.60 hardcoded.
    def similarity_threshold(phase)
      Calvin::CONFIG.dig(:rag, :similarity_threshold, phase.to_sym) ||
        Calvin::CONFIG.dig(:rag, :similarity_threshold)              ||
        0.60
    end

    def target_repo
      Calvin::CONFIG.dig(:rag, :target_repo) or
        raise "rag.target_repo non configurato in config/calvin.yml"
    end

    def embed(query)
      api_key = ENV.fetch("MISTRAL_API_KEY")
      # NOTA: l'API Mistral /v1/embeddings usa il campo `input` (non `inputs`)
      payload = { model: embed_model, input: [query] }.to_json

      http = Net::HTTP.new(EMBED_URL.host, EMBED_URL.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Post.new(EMBED_URL)
      req["Authorization"]   = "Bearer #{api_key}"
      req["Content-Type"]    = "application/json"
      # Forza risposta non compressa: Net::HTTP non decomprime automaticamente gzip
      # e un body gzip causa JSON.parse failure con "unexpected character: '?'"
      req["Accept-Encoding"] = "identity"
      req.body = payload

      resp = http.request(req)
      Calvin::LOG.info "ContextRetriever[embed]: HTTP #{resp.code}, content-encoding=#{resp['content-encoding'].inspect}"
      raise "Mistral embed HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)

      data = JSON.parse(resp.body)
      data.dig("data", 0, "embedding") or raise "embedding non trovato nella risposta"
    end

    # Usato da explore e implement — cerca solo source_type='rule' (hardcodato nella RPC).
    def search_rules(embedding, top_k)
      url     = URI("#{ENV['SUPABASE_URL']}/rest/v1/rpc/calvin_rules_search")
      api_key = ENV.fetch("SUPABASE_SERVICE_KEY")

      payload = {
        query_embedding: embedding,
        match_count:     top_k,
        target_repo:     target_repo
      }.to_json

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Post.new(url)
      req["apikey"]          = api_key
      req["Authorization"]   = "Bearer #{api_key}"
      req["Content-Type"]    = "application/json"
      req["Accept-Encoding"] = "identity"
      req.body = payload

      resp = http.request(req)
      Calvin::LOG.info "ContextRetriever[supabase]: HTTP #{resp.code}, content-encoding=#{resp['content-encoding'].inspect}, body_size=#{resp.body.bytesize}"
      raise "Supabase RPC HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end

    # Usato da call_for_test — cerca su più source_types via calvin_context_search.
    def search_context(embedding, top_k, source_types)
      url     = URI("#{ENV['SUPABASE_URL']}/rest/v1/rpc/calvin_context_search")
      api_key = ENV.fetch("SUPABASE_SERVICE_KEY")

      payload = {
        query_embedding: embedding,
        match_count:     top_k,
        target_repo:     target_repo,
        source_types:    source_types
      }.to_json

      http = Net::HTTP.new(url.host, url.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Post.new(url)
      req["apikey"]          = api_key
      req["Authorization"]   = "Bearer #{api_key}"
      req["Content-Type"]    = "application/json"
      req["Accept-Encoding"] = "identity"
      req.body = payload

      resp = http.request(req)
      Calvin::LOG.info "ContextRetriever[supabase/context]: HTTP #{resp.code}, content-encoding=#{resp['content-encoding'].inspect}, body_size=#{resp.body.bytesize}"
      raise "Supabase RPC HTTP #{resp.code}: #{resp.body[0..200]}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end

    def embed_model
      Calvin::CONFIG.dig(:rag, :embed_model) || "mistral-embed"
    end

    def format_rules(chunks)
      chunks.map.with_index(1) do |c, i|
        sim = c["similarity"].to_f.round(3)
        "#{i}. [#{c['source_path']} sim=#{sim}]\n#{c['content']}"
      end.join("\n\n")
    end

    def log_chunks(chunks, phase = "unknown")
      chunks.each do |c|
        Calvin::LOG.info "ContextRetriever[#{phase}]:   accept #{c['source_path']} sim=#{c['similarity'].to_f.round(3)}"
      end
    end
  end
end
