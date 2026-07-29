# frozen_string_literal: true
# Calvin::Decisions — i vincoli che non si possono dedurre leggendo il codice.
#
# È l'unica categoria di conoscenza che giustifica un intervento umano ricorrente, e
# proprio per questo NON passa da un DB vettoriale:
#
#   - sono poche (decine di righe), quindi le vuoi tutte: non c'è nulla da selezionare
#   - non sono verificabili, altrimenti sarebbero gate in Validator
#   - non sono visibili nel codice — o peggio, il codice contiene sia il pattern nuovo
#     sia quello legacy, e solo un umano sa quale dei due è quello giusto
#
# Esempi di ciò che appartiene qui:
#   "Le API pubbliche versionano (api/v1), le interne no."
#   "Order#status è deprecato: usare Order#state. La colonna vecchia esiste ancora."
#   "Notifiche via ActiveJob sulla coda :mailers — Sidekiq non è nello stack."
#
# Esempi di ciò che NON appartiene qui:
#   "I model non contengono validates."          → gate in Validator (verificabile)
#   "I controller chiamano un service."          → reference pattern (visibile nel codice)
#
# Formati accettati per .calvin/decisions.yml nel repo target — stringa nuda, oppure hash.
# Il formato ricco è quello che il template calvin_context/decisions.yml già usava
# (`decision` + `rationale` + `source`): il rationale entra nel prompt fra parentesi,
# perché il "perché" impedisce al modello di generalizzare la regola oltre il suo dominio.
#
#   - "Le API pubbliche versionano (api/v1), le interne no."
#
#   - text: "I job di notifica usano la coda :mailers."
#     scope: job
#
#   - date: "2026-07-15"
#     decision: "Usare dry-validation per tutti i contract di input."
#     rationale: "Layer di validazione unico, coerente con dry-rb già nello stack."
#     source: "PR #42"
#     scope: contract
#
# .load(workspace)                → Calvin::Decisions::Set
# set.for_scopes(["controller"])  → [String]  (globali + quelle degli scope richiesti)
# set.to_prompt_section(scopes:)  → String | nil

require "yaml"

module Calvin
  module Decisions
    PATH = ".calvin/decisions.yml"

    Set = Data.define(:entries, :source) do
      def any? = !entries.empty?

      def size = entries.size

      # Le decisioni senza scope valgono sempre; quelle con scope solo per i layer toccati.
      def for_scopes(scopes)
        wanted = Array(scopes).compact.map(&:to_s)
        entries.filter_map do |e|
          next e[:text] if e[:scope].nil?

          e[:text] if wanted.include?(e[:scope])
        end
      end

      def to_prompt_section(scopes: nil, budget_bytes: nil)
        texts = scopes ? for_scopes(scopes) : entries.map { |e| e[:text] }
        return nil if texts.empty?

        texts = truncate(texts, budget_bytes) if budget_bytes

        header = "## Project decisions — non-negotiable constraints that cannot be inferred from the code\n" \
                 "These override any pattern you see in the codebase: the codebase may still contain legacy code."

        "#{header}\n\n#{texts.map { |t| "- #{t}" }.join("\n")}"
      end

      private

      # Le decisioni sono ordinate come le ha scritte l'umano: se il budget è stretto si
      # tagliano dalla fine, non si riordinano.
      def truncate(texts, budget)
        kept  = []
        total = 0
        texts.each do |t|
          size = t.bytesize + 3
          break if total + size > budget

          kept  << t
          total += size
        end
        kept
      end
    end

    EMPTY = Set.new(entries: [], source: :none)

    # workspace: Calvin::Workspace | nil — se il clone non c'è, nessuna decisione.
    def self.load(workspace)
      return EMPTY unless workspace&.available?

      raw = workspace.read(PATH)
      return EMPTY if raw.nil? || raw.strip.empty?

      entries = parse(YAML.safe_load(raw))
      Calvin::LOG.info "Decisions: #{entries.size} vincolo/i da #{PATH}"
      Set.new(entries: entries, source: :file)
    rescue Psych::SyntaxError => e
      Calvin::LOG.warn "Decisions: #{PATH} non è YAML valido (#{e.message}) — ignorato"
      EMPTY
    rescue => e
      Calvin::LOG.warn "Decisions: lettura di #{PATH} fallita — #{e.class}: #{e.message}"
      EMPTY
    end

    # Accetta sia la lista nuda che un hash con chiave `decisions`, così il file può
    # crescere con altri campi senza rompere il parsing.
    def self.parse(data)
      list = case data
      when Array then data
      when Hash  then data["decisions"] || data[:decisions] || []
      else []
      end

      Array(list).filter_map do |item|
        case item
        when String
          text = item.strip
          { text: text, scope: nil } unless text.empty?
        when Hash
          parse_entry(item)
        end
      end
    end

    # `text` è la forma minima; `decision` + `rationale` è il formato del log di decisioni.
    def self.parse_entry(item)
      fetch = ->(key) { (item[key.to_s] || item[key]).to_s.strip }

      text = fetch.call(:text)
      text = fetch.call(:decision) if text.empty?
      return nil if text.empty?

      rationale = fetch.call(:rationale)
      text      = "#{text.sub(/\.\z/, '')} — #{rationale.sub(/\.\z/, '')}." unless rationale.empty?

      scope = item["scope"] || item[:scope]
      { text: text, scope: scope&.to_s }
    end
    private_class_method :parse_entry
  end
end
