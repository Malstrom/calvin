# frozen_string_literal: true
# Loop ReAct (Reason + Act) per calvin-auto.
#
# Il modello esplora il repo autonomamente tramite tool calls JSON,
# poi segnala "done" quando ha abbastanza contesto per implementare.
#
# Tool disponibili:
#   read_file(path)  → contenuto file o errore
#   list_dir(path)   → lista nomi nel directory
#   done()           → termina il loop; la risposta contiene i FILE: blocks
#
# Formato risposta del modello (sempre JSON su una riga):
#   {"thought": "...", "tool": "...", "args": {...}}
#
# Dopo "done" il modello scrive immediatamente i FILE: blocks.
#
# Fallback: se MAX_TURNS esaurite o JSON non parsabile dopo GRACE_TURNS,
# termina e restituisce il contenuto raw (FileParser gestisce il resto).
#
# .run → { content: String, turns: Integer }

require "json"
require_relative "file_parser"

module Calvin
  class ReActLoop
    MAX_TURNS   = 12
    GRACE_TURNS = 2  # tentativi JSON falliti prima del fallback

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Sei un senior Rails developer che esplora un codebase per implementare un task.

      Rispondi SEMPRE con JSON valido su una riga, con questa struttura:
      {"thought": "...", "tool": "...", "args": {...}}

      Tool disponibili:
      - read_file  -> args: {"path": "app/services/foo.rb"}
      - list_dir   -> args: {"path": "app/models"}
      - done       -> args: {} -- usa SOLO quando hai letto abbastanza per implementare

      Dopo "done", scrivi immediatamente i FILE: blocks nel formato:
      FILE: path/to/file.rb
      ```ruby
      # contenuto completo
      ```

      Regole:
      - Non aggiungere testo tra il JSON e i FILE: blocks.
      - Non fare domande. Non spiegare. Solo JSON + eventualmente FILE: blocks.
      - Leggi sempre almeno i file che modificherai prima di scrivere codice.
    PROMPT

    def initialize(github, issue_prompt)
      @github       = github
      @issue_prompt = issue_prompt
      @messages     = [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user",   content: issue_prompt }
      ]
      @json_failures = 0
    end

    # Ritorna { content: String, turns: Integer }
    def run
      turns = 0

      MAX_TURNS.times do
        turns += 1
        raw    = MistralClient.new.complete_messages(@messages)[:content]
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
          # Il contenuto dei FILE: blocks è nel messaggio successivo
          Calvin::LOG.info "ReAct done dopo #{turns} turn(s)"
          final = MistralClient.new.complete_messages(
            @messages + [{ role: "assistant", content: raw }]
          )[:content]
          return { content: final, turns: turns }
        end

        observation = dispatch_tool(tool, args)
        Calvin::LOG.info "observation (#{tool}): #{observation[0..80]}"

        @messages << { role: "assistant", content: raw }
        @messages << { role: "user",      content: "Observation: #{observation}" }
      end

      # Fallback: MAX_TURNS esaurite, usa l'ultimo messaggio raw
      Calvin::LOG.warn "ReAct MAX_TURNS (#{MAX_TURNS}) esaurite — fallback"
      { content: @messages.last[:content], turns: MAX_TURNS }
    end

    private

    TOOLS = {
      "read_file" => ->(github, args) {
        path = args["path"].to_s.strip
        content = github.get_file_content(path)
        content || "ERROR: file non trovato: #{path}"
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

    # Parsea il JSON dalla risposta del modello.
    # Gestisce il caso in cui sia wrappato in ```json ... ```.
    # Ritorna nil se non parsabile.
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
