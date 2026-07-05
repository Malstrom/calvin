# frozen_string_literal: true
# Loop ReAct (Reason + Act) per Calvin.
#
# Due fasi distinte:
#
#   FASE 1 — EXPLORE (multi-turn)
#     Il modello esplora il repo tramite tool calls JSON.
#     system: config/prompts/{stack}/explore_system.md
#     Termina quando il modello chiama done() o si raggiunge MAX_TURNS.
#
#   FASE 2 — IMPLEMENT (singola chiamata separata)
#     system: Calvin::CONVENTIONS_PATH dal repo target + response_format.md
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
# Stack determinato dalla label dell'issue ("rails" | "flutter").
# Default: "rails".
#
# .run → { content: String, turns: Integer, usage: Hash | nil }

require "json"
require_relative "file_parser"

module Calvin
  class ReActLoop
    MAX_TURNS       = Calvin::CONFIG.dig(:react, :max_turns)       || 30
    GRACE_TURNS     = Calvin::CONFIG.dig(:react, :grace_turns)     || 2
    NOT_FOUND_LIMIT = Calvin::CONFIG.dig(:react, :not_found_limit) || 3

    FALLBACK_CONVENTIONS = "You are a senior Rails developer. Follow the project conventions you have read during exploration."

    PROMPTS_DIR = File.expand_path("../../config/prompts", __FILE__)

    def initialize(github, issue_prompt, stack: "rails")
      @github       = github
      @issue_prompt = issue_prompt
      @stack        = stack
      @mistral      = MistralClient.new
      @observations     = []
      @json_failures    = 0
      @not_found_streak = 0
      setup_messages
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

    def load_response_format
      path    = File.join(PROMPTS_DIR, @stack, "response_format.md")
      content = File.read(path, encoding: "UTF-8")
      Calvin::LOG.info "ReActLoop: loaded response_format for stack=#{@stack} (#{content.bytesize} bytes)"
      content
    rescue Errno::ENOENT
      Calvin::LOG.warn "ReActLoop: response_format.md not found for stack=#{@stack}, using rails fallback"
      File.read(File.join(PROMPTS_DIR, "rails", "response_format.md"), encoding: "UTF-8")
    end

    def load_conventions
      raw = @github.get_file_content(Calvin::CONVENTIONS_PATH)
      if raw
        content = raw.force_encoding("UTF-8")
        Calvin::LOG.info "load_conventions: loaded #{Calvin::CONVENTIONS_PATH} (#{content.bytesize} bytes)"
        content
      else
        Calvin::LOG.warn "load_conventions: #{Calvin::CONVENTIONS_PATH} not found — using fallback"
        FALLBACK_CONVENTIONS
      end
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
      raw = @mistral.complete_messages(@messages)[:content]
      Calvin::LOG.info "ReAct turn: #{raw[0..120]}"
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
      Calvin::LOG.info "implement_phase after #{turns} explore turn(s)"

      conventions      = load_conventions
      response_format  = load_response_format
      implement_system = "#{conventions}\n\n#{response_format}"
      implement_user   = build_implement_user

      response = @mistral.complete_messages([
        { role: "system", content: implement_system },
        { role: "user",   content: implement_user }
      ])

      { content: response[:content], turns: turns, usage: response[:usage] }
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
