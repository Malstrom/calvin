# frozen_string_literal: true
# Loop ReAct (Reason + Act) per calvin-auto.
#
# Due fasi distinte:
#
#   FASE 1 — EXPLORE (multi-turn)
#     Il modello esplora il repo tramite tool calls JSON.
#     system: EXPLORE_SYSTEM (regole tool + ordine esplorazione, solo JSON)
#     Termina quando il modello chiama done() o si raggiunge MAX_TURNS.
#
#   FASE 2 — IMPLEMENT (singola chiamata separata)
#     system: contenuto di .calvin/prompt dal repo target + RESPONSE_FORMAT
#     user:   prompt issue + observations collassate dall'esplorazione
#     Il modello scrive i FILE: blocks e il PR_BODY.
#
# Tool disponibili durante l'esplorazione:
#   read_file(path)  → contenuto file o errore
#   list_dir(path)   → lista nomi nella directory
#   done()           → termina l'esplorazione e avvia implement_phase
#
# Formato risposta modello durante esplorazione (sempre JSON su una riga):
#   {"thought": "...", "tool": "...", "args": {...}}
#
# .run → { content: String, turns: Integer, usage: Hash | nil }

require "json"
require_relative "file_parser"

module Calvin
  class ReActLoop
    MAX_TURNS       = Calvin::CONFIG.dig(:react, :max_turns)       || 30
    GRACE_TURNS     = Calvin::CONFIG.dig(:react, :grace_turns)     || 2
    NOT_FOUND_LIMIT = Calvin::CONFIG.dig(:react, :not_found_limit) || 3

    CALVIN_PROMPT_PATH   = ".calvin/prompt"
    FALLBACK_CONVENTIONS = "You are a senior Rails developer. Follow the project conventions you have read during exploration."

    # System message fase 1: solo regole esplorazione e tool grammar.
    # Niente Ruby, niente formato output — il modello è in "explorer mode".
    EXPLORE_SYSTEM = <<~PROMPT.freeze
      You are a senior Rails developer exploring a codebase to gather context for a task.

      Always respond with valid JSON on a single line:
      {"thought": "...", "tool": "...", "args": {...}}

      Available tools:
      - read_file  -> args: {"path": "app/services/foo.rb"}
      - list_dir   -> args: {"path": "app/models"}
      - done       -> args: {}

      CRITICAL rules:
      - Call "done" as soon as you have read the main files (model, reference controller, serializer, routes).
      - Do NOT look for test files before calling done — test exploration happens after done.
      - If a file does not exist (ERROR: file not found), do NOT retry variants: move on or call "done".
      - Maximum 3 consecutive NOT_FOUND errors before calling "done".
      - No questions. JSON only.

      ===== TEST EXPLORATION (after done, before writing tests) =====
      Before writing any test, explore ALWAYS in this order:
      1. .calvin/testing.yml       — conventions, base classes (ApiTestCase), available helpers
                                     (auth_headers, post_json, put_json), fixture catalogue,
                                     forbidden patterns (e.g. user.jwt does not exist)
      2. test/test_helper.rb       — real definition of ApiTestCase and helpers
      3. test/fixtures/            — list existing fixtures
      4. the relevant fixture file — to know which records are available
      5. an existing similar test  — to learn style and reuse helpers
      Reuse existing helpers and fixture rows. Create new ones only if they do not exist.
      NEVER use user.jwt or users(:name).jwt — it does not exist. Always use auth_headers(users(:name)).
    PROMPT

    # Formato output: definito una sola volta, usato solo nella fase implement.
    RESPONSE_FORMAT = <<~FORMAT.freeze
      ## Output format

      For every file to create or modify, output a FILE: block:

      FILE: path/to/file.rb
      ```ruby
      # complete file content
      ```

      Rules:
      - One FILE: block per file.
      - New files: full content from scratch.
      - Modified files: complete updated file, not a diff.
      - Use the correct language fence (ruby, yml, sql, etc.).
      - No text between FILE: blocks.
      - Write implementation files first, then test files.
      - Tests are MANDATORY — one test file per new non-test .rb file.
      - Minimum test coverage:
          - Controller: 401 (no token) + 422 (invalid params) + 200 (happy path)
          - Service/contract: one valid input + one failure per validated field

      After all FILE: blocks, write a PR description:

      PR_BODY_START
      ## What this does
      - <concise bullet>

      ## Decisions made
      - <decision and why — be specific, reference actual class/field names>

      ## Alternatives rejected
      - <alternative> — <why rejected>

      ## Risks
      - Product: <risk or "none">
      - Technical: <risk or "none">
      PR_BODY_END

      Always include PR_BODY_START/PR_BODY_END. Never leave placeholder text in the output.
    FORMAT

    def initialize(github, issue_prompt)
      @github           = github
      @issue_prompt     = issue_prompt
      @mistral          = MistralClient.new
      @messages         = [
        { role: "system", content: EXPLORE_SYSTEM },
        { role: "user",   content: issue_prompt }
      ]
      @observations     = []
      @json_failures    = 0
      @not_found_streak = 0
    end

    # Ritorna { content: String, turns: Integer, usage: Hash | nil }
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

    # Esegue un singolo turn di esplorazione.
    # Ritorna:
    #   :done     — il modello ha chiamato done(), avvia implement_phase
    #   :abort    — troppi JSON parse failure, interrompi il loop
    #   :continue — appendi observation e prosegui
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
      raw = @mistral.complete_messages(@messages)[:content]
      Calvin::LOG.info "ReAct turn: #{raw[0..120]}"
      raw
    end

    def handle_json_failure(n)
      @json_failures += 1
      Calvin::LOG.warn "JSON parse failed (#{@json_failures}/#{GRACE_TURNS}) at turn #{n}"
      @json_failures >= GRACE_TURNS ? :abort : :continue
    end

    # Ritorna :done se raggiunti NOT_FOUND_LIMIT consecutivi, altrimenti :continue.
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
      Calvin::LOG.info "implement_phase after #{turns} explore turn(s)"

      conventions      = load_conventions
      implement_system = "#{conventions}\n\n#{RESPONSE_FORMAT}"
      implement_user   = build_implement_user

      response = @mistral.complete_messages([
        { role: "system", content: implement_system },
        { role: "user",   content: implement_user }
      ])

      { content: response[:content], turns: turns, usage: response[:usage] }
    end

    def load_conventions
      content = @github.get_file_content(CALVIN_PROMPT_PATH)
      if content
        Calvin::LOG.info "load_conventions: loaded #{CALVIN_PROMPT_PATH} (#{content.bytesize} bytes)"
        content
      else
        Calvin::LOG.warn "load_conventions: #{CALVIN_PROMPT_PATH} not found — using fallback"
        FALLBACK_CONVENTIONS
      end
    end

    def build_implement_user
      context_block = if @observations.any?
        lines = @observations.map { |o| "#{o[:label]}:\n#{o[:content]}" }.join("\n\n---\n\n")
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

      @observations << { label: label, content: observation }
    end

    # ---------------------------------------------------------------------------
    # Tool dispatch
    # ---------------------------------------------------------------------------

    TOOLS = {
      "read_file" => ->(github, args) {
        path = args["path"].to_s.strip
        github.get_file_content(path) || "ERROR: file not found: #{path}"
      },
      "list_dir" => ->(github, args) {
        path = args["path"].to_s.strip
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
