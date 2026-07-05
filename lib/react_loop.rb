# frozen_string_literal: true
# Loop ReAct (Reason + Act) per Calvin.
#
# Due fasi distinte:
#
#   FASE 1 — EXPLORE (multi-turn)
#     Il modello esplora il repo tramite tool calls JSON.
#     system: config/prompts/{stack}/explore_system.md
#     Termina quando il modello chiama done() o si raggiunge MAX_TURNS.
#     temperature: sampling.temperature.explore (default 0.1)
#
#   FASE 2 — IMPLEMENT (singola chiamata separata)
#     system: config/prompts/{stack}/implement_system.md
#     user:   prompt issue + observations collassate dall'esplorazione
#     Il modello scrive i FILE: blocks e il PR_BODY.
#     temperature: sampling.temperature.implement (default 0.0)
#
# Tool disponibili durante l'esplorazione:
#   read_file(path)  → contenuto file o errore
#   list_dir(path)   → lista nomi nella directory
#   done()           → termina l'esplorazione e avvia implement_phase
#
# Formato risposta modello durante esplorazione (sempre JSON):
#   {"thought": "...", "tool": "...", "args": {...}}
#   Accettato sia su una riga che multi-riga (parse robusto).
#
# Stack determinato dalla label dell'issue ("rails" | "flutter").
# Default: "rails".
#
# .run → { content: String, turns: Integer, usage: Hash | nil, temperature: Float }

module Calvin
  class ReActLoop
    MAX_TURNS       = Calvin::CONFIG.dig(:react, :max_turns)       || 30
    GRACE_TURNS     = Calvin::CONFIG.dig(:react, :grace_turns)     || 2
    NOT_FOUND_LIMIT = Calvin::CONFIG.dig(:react, :not_found_limit) || 3

    PROMPTS_DIR = File.expand_path("../../config/prompts", __FILE__)

    def initialize(github, issue_prompt, stack: "rails")
      @github       = github
      @issue_prompt = issue_prompt
      @stack        = stack
      @mistral      = MistralClient.new
      @observations     = []
      @json_failures    = 0
      @not_found_streak = 0

      sampling        = Calvin::CONFIG.dig(:sampling, :temperature) || {}
      @temp_explore   = sampling[:explore]   || sampling["explore"]   || 0.1
      @temp_implement = sampling[:implement] || sampling["implement"] || 0.0

      setup_messages
    end

    # Ritorna { content: String, turns: Integer, usage: Hash | nil, temperature: Float }
    def run
      MAX_TURNS.times do |i|
        n      = i + 1
        result = process_turn(n)
        return implement_phase(n) if result == :done
        break                     if result == :abort
      end

      Calvin::LOG.warn "ReAct MAX_TURNS (#{MAX_TURNS}) reached — forcing implement"
      implement_phase(MAX_TURNS)
    end

    private

    def setup_messages
      @messages = [
        { role: "system", content: load_explore_system },
        { role: "user",   content: @issue_prompt }
      ]
    end

    # ---------------------------------------------------------------------------
    # Prompt loading
    # ---------------------------------------------------------------------------

    def load_explore_system
      path    = File.join(PROMPTS_DIR, @stack, "explore_system.md")
      content = File.read(path, encoding: "UTF-8")
      Calvin::LOG.info "ReActLoop: loaded explore_system for stack=#{@stack} (#{content.bytesize} bytes)"
      content
    rescue Errno::ENOENT
      Calvin::LOG.warn "ReActLoop: explore_system.md not found for stack=#{@stack}, using rails fallback"
      File.read(File.join(PROMPTS_DIR, "rails", "explore_system.md"), encoding: "UTF-8")
    end

    def load_implement_system
      path    = File.join(PROMPTS_DIR, @stack, "implement_system.md")
      content = File.read(path, encoding: "UTF-8")
      Calvin::LOG.info "ReActLoop: loaded implement_system for stack=#{@stack} (#{content.bytesize} bytes)"
      content
    rescue Errno::ENOENT
      Calvin::LOG.warn "ReActLoop: implement_system.md not found for stack=#{@stack}, using rails fallback"
      File.read(File.join(PROMPTS_DIR, "rails", "implement_system.md"), encoding: "UTF-8")
    end

    # ---------------------------------------------------------------------------
    # Explore loop
    # ---------------------------------------------------------------------------

    def process_turn(n)
      raw    = call_model
      action = parse_action(raw)

      return handle_json_failure(n) if action.nil?

      @json_failures = 0
      tool = action["tool"]
      args = action["args"] || {}

      if tool == "done"
        Calvin::LOG.info "ReAct explore done after #{n} turn(s)"
        return :done
      end

      observation = dispatch_tool(tool, args)
      Calvin::LOG.info "observation (#{tool}): #{observation[0..80]}"

      record_observation(tool, args, observation)
      append_turn(raw, observation)

      handle_not_found(observation, n)
    end

    def call_model
      raw = @mistral.complete_messages(@messages, temperature: @temp_explore)[:content]
      Calvin::LOG.info "ReAct turn (temp=#{@temp_explore}): #{raw[0..120]}"
      raw
    end

    def handle_json_failure(n)
      @json_failures += 1
      Calvin::LOG.warn "JSON parse failed (#{@json_failures}/#{GRACE_TURNS}) at turn #{n}"
      @json_failures >= GRACE_TURNS ? :abort : :continue
    end

    def handle_not_found(observation, n)
      if observation.start_with?("ERROR:")
        @not_found_streak += 1
        if @not_found_streak >= NOT_FOUND_LIMIT
          Calvin::LOG.warn "#{NOT_FOUND_LIMIT} consecutive NOT_FOUND at turn #{n} — forcing implement"
          return :done
        end
      else
        @not_found_streak = 0
      end
      :continue
    end

    def append_turn(raw, observation)
      @messages << { role: "assistant", content: raw }
      @messages << { role: "user",      content: "Observation: #{observation}" }
    end

    # ---------------------------------------------------------------------------
    # Fase 2 — implement
    # ---------------------------------------------------------------------------

    def implement_phase(turns)
      Calvin::LOG.info "implement_phase after #{turns} explore turn(s) (temp=#{@temp_implement})"

      response = @mistral.complete_messages(
        [
          { role: "system", content: load_implement_system },
          { role: "user",   content: build_implement_user }
        ],
        temperature: @temp_implement
      )

      { content: response[:content], turns: turns, usage: response[:usage], temperature: @temp_implement }
    end

    def build_implement_user
      context_block = if @observations.any?
        lines = @observations.map { |o| "#{o[:label]}:\n#{o[:content].force_encoding('UTF-8')}" }.join("\n\n---\n\n")
        "## Context gathered during exploration\n\n#{lines}"
      end

      ["## Task", @issue_prompt, context_block].compact.reject(&:empty?).join("\n\n")
    end

    def record_observation(tool, args, observation)
      return if observation.start_with?("ERROR:")

      label = case tool
              when "read_file" then args["path"].to_s.strip
              when "list_dir"  then "ls #{args['path'].to_s.strip}"
              else tool
              end

      @observations << { label: label, content: observation.force_encoding("UTF-8") }
    end

    # ---------------------------------------------------------------------------
    # Tool dispatch
    # ---------------------------------------------------------------------------

    TOOLS = {
      "read_file" => ->(github, args) {
        path    = args["path"].to_s.strip
        content = github.get_file_content(path)
        content ? content.force_encoding("UTF-8") : "ERROR: file not found: #{path}"
      },
      "list_dir" => ->(github, args) {
        path    = args["path"].to_s.strip
        entries = github.list_directory(path)
        entries.any? ? entries.join("\n") : "ERROR: empty or not found: #{path}"
      }
    }.freeze

    def dispatch_tool(tool, args)
      handler = TOOLS[tool]
      unless handler
        Calvin::LOG.warn "Unknown tool: #{tool}"
        return "ERROR: unknown tool '#{tool}'. Use: read_file, list_dir, done."
      end
      handler.call(@github, args)
    rescue => e
      "ERROR: #{e.message}"
    end

    # Parsa il JSON prodotto dal modello in modo robusto.
    #
    # Codestral può rispondere in tre forme:
    #   1. One-liner:   {"thought": "...", "tool": "read_file", "args": {...}}
    #   2. Multi-riga:  oggetto JSON spalmato su più righe
    #   3. Con fence:   ```json\n{...}\n```
    #
    # Strategia:
    #   a. Rimuovi fence markdown se presenti
    #   b. Prova JSON.parse sull'intero testo (caso multi-riga)
    #   c. Se fallisce, cerca la prima riga che inizia con '{' (caso one-liner)
    #   d. Se nessuno funziona → nil → handle_json_failure
    def parse_action(raw)
      cleaned = raw.strip
                   .gsub(/\A```(?:json)?\s*\n?/, "")
                   .gsub(/\n?```\s*\z/, "")
                   .strip

      # Tentativo 1: intero contenuto come JSON (multi-riga e one-liner)
      return JSON.parse(cleaned) if cleaned.start_with?("{")

      # Tentativo 2: prima riga che inizia con '{' (modello ha aggiunto testo prima)
      first_json_line = cleaned.lines.find { |l| l.strip.start_with?("{") }&.strip
      return JSON.parse(first_json_line) if first_json_line

      nil
    rescue JSON::ParserError => e
      Calvin::LOG.warn "ReAct JSON error: #{e.message.lines.first&.strip}"
      nil
    end
  end
end
