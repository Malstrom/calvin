# frozen_string_literal: true
# Calvin::LearningStore — persiste gli errori che Calvin commette e come finiscono.
#
# Sostituisce il loop manuale "un LLM estrae regole da un diff → commento con checkbox →
# approvazione → embedding". Quel meccanismo chiedeva a un umano di validare
# un'affermazione generalizzata da un solo diff. Qui l'evidenza è già disponibile e non
# costa nulla: ogni volta che un gate va rosso, Calvin conosce il gate, l'errore esatto, il
# codice sbagliato e quello corretto. Aggregati su molti run, gli errori ricorrenti dicono
# dove serve un gate nuovo o un esempio migliore.
#
# Tabella RELAZIONALE, non vettoriale: la domanda è "quante volte è capitato questo",
# che è un GROUP BY, non una ricerca per similarità.
#
#   create table calvin_repairs (
#     id bigserial primary key,
#     repo text not null, issue_number int, run_id text,
#     gate text not null, signature text not null,
#     path text, scope text, error_excerpt text,
#     fixed boolean not null, attempt int not null,
#     created_at timestamptz default now()
#   );
#
# .record(events) → Integer (righe scritte) | 0
# .aggregate(repo:, since_days:) → [{ signature:, gate:, scope:, occurrences:, fixed_count:, … }]
#
# Non bloccante come RunReporter: se Supabase è assente o in pausa, logga e prosegue —
# un problema di telemetria non deve mai far fallire un run.

require "net/http"
require "json"
require "uri"
require "time"

module Calvin
  module LearningStore
    extend self

    TABLE        = "calvin_repairs"
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15
    EXCERPT_LIMIT = 600

    def configured?
      !ENV["SUPABASE_URL"].to_s.empty? && !ENV["SUPABASE_SERVICE_KEY"].to_s.empty?
    end

    # events: [{ gate:, signature:, path:, scope:, error_excerpt:, fixed:, attempt: }]
    def record(events, repo: Calvin::REPO, issue_number: nil, run_id: nil)
      rows = Array(events)
      return 0 if rows.empty?

      unless configured?
        Calvin::LOG.info "LearningStore: Supabase non configurato — #{rows.size} evento/i non registrati"
        return 0
      end

      payload = rows.map do |e|
        {
          repo:          repo,
          issue_number:  issue_number,
          run_id:        run_id || ENV["GITHUB_RUN_ID"],
          gate:          e[:gate].to_s,
          signature:     e[:signature].to_s,
          path:          e[:path],
          scope:         e[:scope],
          error_excerpt: e[:error_excerpt].to_s[0, EXCERPT_LIMIT],
          fixed:         e[:fixed] ? true : false,
          attempt:       e[:attempt].to_i
        }
      end

      post_json("/rest/v1/#{TABLE}", payload)
      Calvin::LOG.info "LearningStore: #{payload.size} evento/i registrati (#{payload.map { |p| p[:signature] }.uniq.join(', ')})"
      payload.size
    rescue => e
      Calvin::LOG.warn "LearningStore: scrittura fallita (non bloccante) — #{e.class}: #{e.message}"
      0
    end

    # Aggregazione lato client: PostgREST non fa GROUP BY, e il volume è nell'ordine delle
    # migliaia di righe — non vale una RPC dedicata.
    def aggregate(repo: Calvin::REPO, since_days: 30, all_repos: false)
      raise "Supabase non configurato" unless configured?

      since  = (Time.now.utc - since_days * 86_400).iso8601
      query  = ["select=gate,signature,scope,path,fixed,created_at",
                "created_at=gte.#{since}",
                "order=created_at.desc",
                "limit=5000"]
      query << "repo=eq.#{URI.encode_uri_component(repo)}" unless all_repos

      summarize(get_json("/rest/v1/#{TABLE}?#{query.join('&')}"))
    end

    # Funzione pura, separata dall'I/O per essere testabile senza rete.
    # Raggruppa per (signature, scope): lo stesso errore in due strati diversi resta
    # distinto, perché è l'informazione che dice dove intervenire.
    def summarize(rows)
      Array(rows).group_by { |r| [r["signature"], r["scope"]] }.map do |(signature, scope), group|
        {
          signature:   signature,
          gate:        group.first["gate"],
          scope:       scope,
          occurrences: group.size,
          fixed_count: group.count { |r| r["fixed"] },
          paths:       group.map { |r| r["path"] }.compact.uniq.first(5),
          last_seen:   group.map { |r| r["created_at"] }.compact.max
        }
      end.sort_by { |a| -a[:occurrences] }
    end

    # Classifica un ricorrente in base a frequenza ed esito, secondo la logica:
    #   sempre riparato e frequente  → Calvin sa risolverlo ma solo dopo aver sbagliato:
    #                                  va prevenuto (gate o esempio nel prompt)
    #   mai riparato e frequente     → limite del modello o vincolo mal specificato:
    #                                  serve una decisione umana
    #   raro                         → rumore
    def classify(entry, min_occurrences: 3)
      return :noise if entry[:occurrences] < min_occurrences

      rate = entry[:fixed_count].to_f / entry[:occurrences]
      return :prevent if rate >= 0.8
      return :human   if rate <= 0.2

      :watch
    end

    private

    def base_url = ENV.fetch("SUPABASE_URL").chomp("/")

    def api_key = ENV.fetch("SUPABASE_SERVICE_KEY")

    def http_for(uri)
      http              = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http
    end

    def headers(req)
      req["Content-Type"]    = "application/json"
      req["apikey"]          = api_key
      req["Authorization"]   = "Bearer #{api_key}"
      req["Accept-Encoding"] = "identity"
    end

    def post_json(path, body)
      uri = URI("#{base_url}#{path}")
      req = Net::HTTP::Post.new(uri)
      headers(req)
      req["Prefer"] = "return=minimal"
      req.body      = body.to_json

      resp = http_for(uri).request(req)
      raise "Supabase HTTP #{resp.code}: #{resp.body.to_s[0, 200]}" unless resp.is_a?(Net::HTTPSuccess)

      true
    end

    def get_json(path)
      uri = URI("#{base_url}#{path}")
      req = Net::HTTP::Get.new(uri)
      headers(req)
      req["Accept"] = "application/json"

      resp = http_for(uri).request(req)
      raise "Supabase HTTP #{resp.code}: #{resp.body.to_s[0, 200]}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body.to_s.dup.force_encoding("UTF-8"))
    end
  end
end
