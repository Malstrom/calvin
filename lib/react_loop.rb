# frozen_string_literal: true
# Loop ReAct (Reason + Act) per Calvin.
#
# Due fasi distinte:
#
#   FASE 1 — EXPLORE (multi-turn)
#     Il modello esplora il repo tramite tool calls JSON.
#     system: config/prompts/{stack}/explore_system.md + rules iniettate prima di # Examples
#     Termina quando il modello chiama done() o si raggiunge MAX_TURNS.
#     temperature: sampling.temperature.explore (default 0.1)
#     RAG: Calvin::ContextRetriever.call_for_explore(issue) — query da title+body
#          top_k: rag.top_k_explore (default 10)
#
#   FASE 2 — IMPLEMENT (singola chiamata separata)
#     system: config/prompts/{stack}/implement_system.md (invariato)
#     user:   ## Task + observations categorizzate + ## Rules (RAG) ULTIME
#     Rules RAG iniettate come ULTIMA sezione del messaggio utente per
#     sfruttare il recency bias di Codestral: le sezioni che arrivano per
#     ultime pesano di più durante la generazione.
#     temperature: sampling.temperature.implement (default 0.0)
#     RAG: Calvin::ContextRetriever.call_for_implement(file_plan) — query dai path file
#          top_k: rag.top_k_implement (default 20)
#          Chiamato subito dopo done() — quando il file_plan è noto.
#
# Tool disponibili durante l'esplorazione:
#   read_file(path)  -> contenuto file o errore
#   list_dir(path)   -> lista nomi nella directory
#   done(modify:, create:, reference:) -> termina l'esplorazione e avvia implement_phase
#
# Formato risposta modello durante esplorazione (sempre JSON su una riga):
#   {"thought": "...", "tool": "...", "args": {...}}
#
# Stack determinato dalla label dell'issue ("rails" | "flutter").
# Default: "rails".
#
# .run -> { content: String, turns: Integer, usage: Hash | nil,
#           usage_explore: Hash, temperature: Float,
#           retrieval_explore: RetrievalResult, retrieval_implement: RetrievalResult }

require "json"
require_relative "file_parser"

module Calvin
  class ReActLoop
    MAX_TURNS       = Calvin::CONFIG.dig(:react, :max_turns)       || 30
    GRACE_TURNS     = Calvin::CONFIG.dig(:react, :grace_turns)     || 2
    NOT_FOUND_LIMIT = Calvin::CONFIG.dig(:react, :not_found_limit) || 3

    PROMPTS_DIR = File.expand_path("../../config/prompts", __FILE__)

    def initialize(github, issue_prompt, stack: "rails", retrieval: nil, issue_number: nil)
      @github       = github
      @issue_prompt = issue_prompt
      @stack        = stack

      # Cache key stabile per tutta la fase explore di questo run.
      # Attiva il prefix caching Mistral sul prefisso condiviso (system + issue + rules).
      # Formato: "calvin-{issue_number}-{run_id}" — univoco per run, stabile tra i turni.
      run_id       = Process.pid
      issue_ref    = issue_number || "unknown"
      @explore_cache_key = "calvin-#{issue_ref}-#{run_id}"

      # retrieval_explore: regole orientamento, query da title+body (top_k_explore)
      # Passato dall'esterno da ExploreFlow prima che il loop parta.
      @retrieval_explore = retrieval || RetrievalResult.new(rules: nil, context: nil, chunks: [])

      # retrieval_implement: regole codegen, query dai path file_plan (top_k_implement)
      # Popolato internamente subito dopo done() — quando il file_plan è noto.
      @retrieval_implement = RetrievalResult.new(rules: nil, context: nil, chunks: [])

      @mistral      = MistralClient.new
      @observations     = []
      @file_plan        = nil
      @json_failures    = 0
      @not_found_streak = 0

      # Accumula usage di tutti i turn explore per il breakdown nel PR body
      @usage_explore = { "prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0 }

      sampling        = Calvin::CONFIG.dig(:sampling, :temperature) || {}
      @temp_explore   = sampling[:explore]   || sampling["explore"]   || 0.1
      @temp_implement = sampling[:implement] || sampling["implement"] || 0.0

      setup_messages
    end

    # Ritorna { content: String, turns: Integer, usage: Hash | nil,
    #           usage_explore: Hash, temperature: Float,
    #           retrieval_explore: RetrievalResult, retrieval_implement: RetrievalResult }
    def run
      Calvin::LOG.info "ReActLoop: explore cache_key=#{@explore_cache_key}"

      MAX_TURNS.times do |i|
        n      = i + 1
        result = process_turn(n)
        if result == :done
          verify_observations
          return implement_phase(n)
        end
        break if result == :abort
      end

      Calvin::LOG.warn "ReAct MAX_TURNS (#{MAX_TURNS}) reached — forcing implement"
      verify_observations
      implement_phase(MAX_TURNS)
    end

    private

    def setup_messages
      explore_system = build_explore_system
      Calvin::LOG.info "context[explore_system]: #{explore_system[0..19].inspect}"
      Calvin::LOG.info "context[issue_prompt]:   #{@issue_prompt[0..19].inspect}"

      @messages = [
        { role: "system", content: explore_system },
        { role: "user",   content: @issue_prompt }
      ]
    end

    # ---------------------------------------------------------------------------
    # Prompt assembly
    # ---------------------------------------------------------------------------

    # Phase 1: rules injected just before # Examples (bottom of prompt) so that
    # recency bias keeps them salient during the exploration loop.
    def build_explore_system
      base = load_prompt("explore_system.md")
      return base unless @retrieval_explore.rules

      rules_section = "# Active rules — consult these while deciding which files to read\n\n#{@retrieval_explore.rules}\n"

      if base.include?("# Examples")
        base.sub("# Examples", "#{rules_section}\n# Examples")
      else
        base + "\n\n#{rules_section}"
      end
    end

    # Phase 2: system prompt is clean — rules go into the user message as the
    # LAST section so recency bias makes Codestral apply them during generation.
    def build_implement_system
      load_prompt("implement_system.md")
    end

    def load_prompt(filename)
      path    = File.join(PROMPTS_DIR, @stack, filename)
      content = File.read(path, encoding: "UTF-8")
      Calvin::LOG.info "ReActLoop: loaded #{filename} for stack=#{@stack} (#{content.bytesize} bytes)"
      content
    rescue Errno::ENOENT
      Calvin::LOG.warn "ReActLoop: #{filename} not found for stack=#{@stack}, using rails fallback"
      File.read(File.join(PROMPTS_DIR, "rails", filename), encoding: "UTF-8")
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
        @file_plan = {
          modify:    Array(args["modify"]).map(&:strip),
          create:    Array(args["create"]).map(&:strip),
          reference: Array(args["reference"]).map(&:strip)
        }
        Calvin::LOG.info "done() plan — modify=#{@file_plan[:modify]} create=#{@file_plan[:create]} reference=#{@file_plan[:reference]}"

        # Secondo retrieval RAG: query costruita dai path del file_plan.
        # Fatto qui — dopo done(), prima di implement_phase — così la query
        # riflette esattamente i file che verranno generati o modificati.
        @retrieval_implement = Calvin::ContextRetriever.call_for_implement(@file_plan)
        Calvin::LOG.info "retrieval_implement: #{@retrieval_implement.rules&.bytesize || 0} bytes, #{@retrieval_implement.chunks.size} chunks"

        return :done
      end

      observation = dispatch_tool(tool, args)
      Calvin::LOG.info "observation (#{tool}): #{observation[0..80]}"

      if tool == "read_file" && !observation.start_with?("ERROR:")
        Calvin::LOG.info "context[#{args['path']}]: #{observation[0..19].inspect}"
      end

      record_observation(tool, args, observation)
      append_turn(raw, observation)

      handle_not_found(observation, n)
    end

    def call_model
      # cache_key passato solo durante explore (multi-turn) — attiva prefix caching Mistral.
      resp = @mistral.complete_messages(@messages, temperature: @temp_explore,
                                                   cache_key: @explore_cache_key)

      # Accumula usage explore per il breakdown nel PR body
      if resp[:usage]
        @usage_explore["prompt_tokens"]     += resp[:usage]["prompt_tokens"].to_i
        @usage_explore["completion_tokens"] += resp[:usage]["completion_tokens"].to_i
        @usage_explore["total_tokens"]      += resp[:usage]["total_tokens"].to_i
      end

      raw = resp[:content]
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
    # verify_observations — forza lettura dei file :modify non ancora in observations
    # ---------------------------------------------------------------------------

    def verify_observations
      return unless @file_plan

      @file_plan[:modify].each do |path|
        next if @observations.any? { |o| o[:label] == path }

        Calvin::LOG.warn "verify_observations: '#{path}' in modify plan but not read — forcing read"
        content = @github.get_file_content(path)
        unless content
          Calvin::LOG.warn "verify_observations: '#{path}' not found in repo — skipping"
          next
        end
        record_observation("read_file", { "path" => path }, content.force_encoding("UTF-8"))
      end
    end

    # ---------------------------------------------------------------------------
    # Fase 2 — implement
    # ---------------------------------------------------------------------------

    def implement_phase(turns)
      Calvin::LOG.info "implement_phase after #{turns} explore turn(s) (temp=#{@temp_implement})"
      Calvin::LOG.info "usage_explore: prompt=#{@usage_explore['prompt_tokens']} completion=#{@usage_explore['completion_tokens']} total=#{@usage_explore['total_tokens']} across #{turns} turn(s)"

      implement_system = build_implement_system
      Calvin::LOG.info "context[implement_system]: #{implement_system[0..19].inspect}"

      implement_user = build_implement_user
      Calvin::LOG.info "context[implement_user]:   #{implement_user[0..19].inspect}"

      # Implement è una singola chiamata — nessun cache_key (prefix caching non ha beneficio).
      response = @mistral.complete_messages(
        [
          { role: "system", content: implement_system },
          { role: "user",   content: implement_user }
        ],
        temperature: @temp_implement
      )

      {
        content:              response[:content],
        turns:                turns,
        usage:                response[:usage],
        usage_explore:        @usage_explore,
        temperature:          @temp_implement,
        retrieval_explore:    @retrieval_explore,
        retrieval_implement:  @retrieval_implement
      }
    end

    def build_implement_user
      sections = ["## Task", @issue_prompt]

      if @file_plan && @observations.any?
        modify_obs    = observations_for(@file_plan[:modify])
        reference_obs = observations_for(@file_plan[:reference])
        other_obs     = @observations.reject do |o|
          (@file_plan[:modify] + @file_plan[:create] + @file_plan[:reference]).include?(o[:label])
        end

        if modify_obs.any?
          sections << "## Files to MODIFY — make surgical changes only, preserve everything not explicitly mentioned"
          modify_obs.each { |o| sections << "### #{o[:label]}\n#{o[:content].force_encoding('UTF-8')}" }
        end

        if @file_plan[:create].any?
          sections << "## Files to CREATE — generate from scratch"
          @file_plan[:create].each { |path| sections << "### #{path}\n(file does not exist yet)" }
        end

        if reference_obs.any?
          sections << "## Reference patterns — follow these conventions, do NOT output FILE blocks for these paths"
          reference_obs.each { |o| sections << "### #{o[:label]}\n#{o[:content].force_encoding('UTF-8')}" }
        end

        if other_obs.any?
          sections << "## Additional context"
          other_obs.each { |o| sections << "#{o[:label]}:\n#{o[:content].force_encoding('UTF-8')}" }
        end
      elsif @observations.any?
        lines = @observations.map { |o| "#{o[:label]}:\n#{o[:content].force_encoding('UTF-8')}" }.join("\n\n---\n\n")
        sections << "## Context gathered during exploration\n\n#{lines}"
      end

      # Rules iniettate ULTIME — recency bias: Codestral pesa di più le sezioni finali.
      # Usa retrieval_implement (query dai path) se disponibile, altrimenti fallback
      # su retrieval_explore (query dall'issue) per garantire sempre una copertura.
      active_rules = @retrieval_implement.rules || @retrieval_explore.rules
      if active_rules
        source = @retrieval_implement.rules ? "implement" : "explore (fallback)"
        sections << "## Rules — apply all of these without exception"
        sections << active_rules
        Calvin::LOG.info "context[rules/#{source}]: #{active_rules.bytesize} bytes injected LAST into user message"
      end

      sections.compact.reject(&:empty?).join("\n\n")
    end

    def observations_for(paths)
      paths.filter_map { |path| @observations.find { |o| o[:label] == path } }
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

      return JSON.parse(cleaned.strip) if cleaned.strip.start_with?("{")

      if (m = cleaned.match(/(\{.+\})/m))
        return JSON.parse(m[1])
      end

      nil
    rescue JSON::ParserError => e
      Calvin::LOG.warn "ReAct JSON error: #{e.message}"
      nil
    end
  end
end
