# frozen_string_literal: true
# Loop ReAct (Reason + Act) per calvin-auto.
#
# Il modello esplora il repo autonomamente tramite tool calls JSON,
# poi segnala "done" quando ha abbastanza contesto per implementare.
#
# Tool disponibili:
#   read_file(path)  → contenuto file o errore
#   list_dir(path)   → lista nomi nel directory
#   done()           → termina il loop; risposta con FILE: blocks
#
# Formato risposta del modello (sempre JSON su una riga):
#   {"thought": "...", "tool": "...", "args": {...}}
#
# Dopo "done" il modello scrive immediatamente i FILE: blocks.
#
# Fallback su MAX_TURNS: forza una chiamata finale chiedendo esplicitamente
# di implementare con il contesto già raccolto.
#
# .run → { content: String, turns: Integer }

require "json"
require_relative "file_parser"

module Calvin
  class ReActLoop
    MAX_TURNS       = 30
    GRACE_TURNS     = 2
    NOT_FOUND_LIMIT = 3

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un senior Rails developer che esplora un codebase per implementare un task.

      Rispondi SEMPRE con JSON valido su una riga:
      {"thought": "...", "tool": "...", "args": {...}}

      Tool disponibili:
      - read_file  -> args: {"path": "app/services/foo.rb"}
      - list_dir   -> args: {"path": "app/models"}
      - done       -> args: {}

      Regole CRITICHE:
      - Chiama "done" non appena hai letto i file principali (modello, controller di riferimento, serializer, routes).
      - NON cercare file di test prima di implementare.
      - Se un file non esiste (ERROR: file non trovato), NON riprovare varianti: vai avanti o chiama "done".
      - Massimo 3 errori NOT_FOUND consecutivi prima di chiamare "done".
      - Non fare domande. Solo JSON.

      ===== ESPLORAZIONE TEST =====
      Prima di scrivere i test, esplora SEMPRE in questo ordine:
      1. .calvin/testing.yml       — convenzioni, classi base (ApiTestCase), helper disponibili
                                     (auth_headers, post_json, put_json), fixture catalogue,
                                     pattern proibiti (es. user.jwt non esiste)
      2. test/test_helper.rb       — definizione reale di ApiTestCase e degli helper
      3. test/fixtures/            — lista fixture esistenti
      4. il file fixture rilevante — per conoscere i record disponibili
      5. un test simile esistente  — per capire lo stile e riusare helper
      Riusa helper e fixture esistenti. Crea nuovi helper/fixture solo se non esistono.
      MAI usare user.jwt o users(:name).jwt — non esiste. Usa sempre auth_headers(users(:name)).

      ===== OUTPUT DOPO "done" =====
      Scrivi i FILE: blocks in quest'ordine:
      1. File di implementazione (migration, model, contract, service, serializer, controller)
      2. File di test (OBBLIGATORI — uno per ogni file .rb nuovo non di test)

      Formato:
      FILE: path/to/file.rb
      ```ruby
      # contenuto completo
      ```

      Test — copertura minima:
      - Almeno un happy path + un error/edge path per ogni metodo pubblico
      - Controller: sempre 401 (no token) + 422 (params invalidi) + 200 (happy path)
      - I test NON sono opzionali.
    PROMPT

    FORCE_IMPLEMENT_MSG = <<~MSG.freeze
      Hai esplorato abbastanza il codebase. Ora implementa il task.
      Scrivi SUBITO i FILE: blocks in quest'ordine:
      1. File di implementazione (migration, model, contract, service, serializer, controller)
      2. File di test (OBBLIGATORI — uno per ogni file .rb nuovo non di test,
         usa le fixture e gli helper che hai letto in .calvin/testing.yml e test/test_helper.rb)
      Non esplorare altro. Non fare domande.
    MSG

    def initialize(github, issue_prompt)
      @github           = github
      @issue_prompt     = issue_prompt
      @mistral          = MistralClient.new
      @messages         = [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user",   content: issue_prompt }
      ]
      @json_failures    = 0
      @not_found_streak = 0
    end

    # Ritorna { content: String, turns: Integer }
    def run
      turns = 0

      MAX_TURNS.times do
        turns += 1
        raw   = @mistral.complete_messages(@messages)[:content]
        Calvin::LOG.info "ReAct turn #{turns}: #{raw[0..120]}"

        action = parse_action(raw)

        if action.nil?
          @json_failures += 1
          Calvin::LOG.warn "JSON parse fallito (#{@json_failures}/#{GRACE_TURNS})"
          break if @json_failures >= GRACE_TURNS
          next
        end

        @json_failures = 0
        tool = action["tool"]
        args = action["args"] || {}

        if tool == "done"
          Calvin::LOG.info "ReAct done dopo #{turns} turn(s)"
          return force_implement(turns)
        end

        observation = dispatch_tool(tool, args)
        Calvin::LOG.info "observation (#{tool}): #{observation[0..80]}"

        if observation.start_with?("ERROR: file non trovato")
          @not_found_streak += 1
          if @not_found_streak >= NOT_FOUND_LIMIT
            Calvin::LOG.warn "#{NOT_FOUND_LIMIT} NOT_FOUND consecutivi — forzo implementazione"
            return force_implement(turns)
          end
        else
          @not_found_streak = 0
        end

        @messages << { role: "assistant", content: raw }
        @messages << { role: "user",      content: "Observation: #{observation}" }
      end

      Calvin::LOG.warn "ReAct MAX_TURNS (#{MAX_TURNS}) esaurite — forzo implementazione"
      force_implement(MAX_TURNS)
    end

    private

    def force_implement(turns)
      Calvin::LOG.info "force_implement dopo #{turns} turn(s)"
      final = @mistral.complete_messages(
        @messages + [{ role: "user", content: FORCE_IMPLEMENT_MSG }]
      )[:content]
      { content: final, turns: turns }
    end

    TOOLS = {
      "read_file" => ->(github, args) {
        path = args["path"].to_s.strip
        github.get_file_content(path) || "ERROR: file non trovato: #{path}"
      },
      "list_dir" => ->(github, args) {
        path = args["path"].to_s.strip
        entries = github.list_directory(path)
        entries.any? ? entries.join("\n") : "ERROR: directory vuota o non trovata: #{path}"
      }
    }.freeze

    def dispatch_tool(tool, args)
      handler = TOOLS[tool]
      unless handler
        Calvin::LOG.warn "Tool sconosciuto: #{tool}"
        return "ERROR: tool sconosciuto '#{tool}'. Usa: read_file, list_dir, done."
      end
      handler.call(@github, args)
    rescue => e
      "ERROR: #{e.message}"
    end

    def parse_action(raw)
      cleaned = raw.strip
                   .gsub(/\A```(?:json)?\n?/, "")
                   .gsub(/\n?```\z/, "")
                   .lines
                   .find { |l| l.strip.start_with?("{") }&.strip
      return nil unless cleaned
      JSON.parse(cleaned)
    rescue JSON::ParseError => e
      Calvin::LOG.warn "ReAct JSON error: #{e.message}"
      nil
    end
  end
end
