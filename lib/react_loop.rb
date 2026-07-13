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
#     system[0]: config/prompts/{stack}/implement_system.md (formato/output)
#     system[1]: ## Rules (RAG chunks) — secondo system message dedicato.
#                Più autorità del user message. Usato se chunks disponibili.
#     user:      ## Task + observations categorizzate (senza ## Rules)
#     Usa retrieval_implement (query dai path) se disponibile, altrimenti
#     fallback su retrieval_explore (query dall'issue).
#     temperature: sampling.temperature.implement (default 0.0)
#     RAG: Calvin::ContextRetriever.call_for_implement(file_plan) — query dai path file
#          top_k: rag.top_k_implement (default 20)
#          Chiamato subito dopo done() — quando il file_plan è noto.
#
# Tool disponibili durante l'esplorazione:
#   read_file(path)              -> contenuto file o errore
#   list_dir(path)               -> lista nomi nella directory
#   grep(pattern:, path:)        -> righe matching in file o directory (case-insensitive)
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

      run_id       = Process.pid
      issue_ref    = issue_number || "unknown"
      @explore_cache_key = "calvin-#{issue_ref}-#{run_id}"

      @retrieval_explore   = retrieval || RetrievalResult.new(rules: nil, context: nil, chunks: [])
      @retrieval_implement = RetrievalResult.new(rules: nil, context: nil, chunks: [])

      @mistral      = MistralClient.new
      @observations     = []
      @file_plan        = nil
      @json_failures    = 0
      @not_found_streak = 0

      @usage_explore = {
        "prompt_tokens"     => 0,
        "completion_tokens" => 0,
        "total_tokens"      => 0,
        "cached_tokens"     => 0
      }

      sampling        = Calvin::CONFIG.dig(:sampling, :temperature) || {}
      @temp_explore   = sampling[:explore]   || sampling["explore"]   || 0.1
      @temp_implement = sampling[:implement] || sampling["implement"] || 0.0

      setup_messages
    end

    def run
      Calvin.banner("EXPLORE", emoji: "🔍")
      Calvin::LOG.info "cache_key=#{@explore_cache_key}  stack=#{@stack}  temp=#{@temp_explore}"

      MAX_TURNS.times do |i|
        n      = i + 1
        result = process_turn(n)
        if result == :done
          verify_observations
          return implement_phase(n)
        end
        break if result == :abort
      end

      Calvin::LOG.warn "MAX_TURNS (#{MAX_TURNS}) reached — forcing implement"
      verify_observations
      implement_phase(MAX_TURNS)
    end

    private

    def setup_messages
      explore_system = build_explore_system
      Calvin::LOG.info "explore_system  #{(explore_system.bytesize / 1024.0).round(1)} KB"
      @messages = [
        { role: "system", content: explore_system },
        { role: "user",   content: @issue_prompt }
      ]
    end

    # ---------------------------------------------------------------------------
    # Prompt assembly
    # ---------------------------------------------------------------------------

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

    def build_implement_system
      load_prompt("implement_system.md")
    end

    def load_prompt(filename)
      path    = File.join(PROMPTS_DIR, @stack, filename)
      content = File.read(path, encoding: "UTF-8")
      Calvin::LOG.info "loaded  #{@stack}/#{filename}  #{(content.bytesize / 1024.0).round(1)} KB"
      content
    rescue Errno::ENOENT
      Calvin::LOG.warn "#{filename} not found for stack=#{@stack}, using rails fallback"
      File.read(File.join(PROMPTS_DIR, "rails", filename), encoding: "UTF-8")
    end

    # ---------------------------------------------------------------------------
    # Explore loop
    # ---------------------------------------------------------------------------

    def process_turn(n)
      raw    = call_model(n)
      action = parse_action(raw)

      return handle_json_failure(n) if action.nil?

      @json_failures = 0
      tool    = action["tool"]
      args    = action["args"] || {}
      thought = action["thought"]

      Calvin.tool_call(n, tool, args, thought: thought)

      if tool == "done"
        @file_plan = {
          modify:    Array(args["modify"]).map(&:strip),
          create:    Array(args["create"]).map(&:strip),
          reference: Array(args["reference"]).map(&:strip)
        }
        Calvin::LOG.info "done()  modify=#{@file_plan[:modify]}  create=#{@file_plan[:create]}  reference=#{@file_plan[:reference]}"

        @retrieval_implement = Calvin::ContextRetriever.call_for_implement(@file_plan)
        Calvin::LOG.info "rag_implement  #{@retrieval_implement.rules&.bytesize || 0} bytes  #{@retrieval_implement.chunks.size} chunks"

        return :done
      end

      observation = dispatch_tool(tool, args)

      if tool == "read_file" && !observation.start_with?("ERROR:")
        Calvin.file_read(args["path"].to_s, observation.bytesize)
      elsif observation.start_with?("ERROR:")
        Calvin::LOG.warn "  #{observation[0..120]}"
      else
        Calvin::LOG.info "  └ #{observation[0..100].gsub(/\n/, ' ')}"
      end

      record_observation(tool, args, observation)
      append_turn(raw, observation)

      handle_not_found(observation, n)
    end

    def call_model(n)
      resp = @mistral.complete_messages(@messages, temperature: @temp_explore,
                                                   cache_key: @explore_cache_key)

      if resp[:usage]
        @usage_explore["prompt_tokens"]     += resp[:usage]["prompt_tokens"].to_i
        @usage_explore["completion_tokens"] += resp[:usage]["completion_tokens"].to_i
        @usage_explore["total_tokens"]      += resp[:usage]["total_tokens"].to_i
        @usage_explore["cached_tokens"]     += resp[:usage].dig("prompt_tokens_details", "cached_tokens").to_i

        pt = resp[:usage]["prompt_tokens"].to_i
        ct = resp[:usage]["completion_tokens"].to_i
        ca = resp[:usage].dig("prompt_tokens_details", "cached_tokens").to_i
        Calvin::LOG.info "  #{Color::DIM}tokens  in=#{pt} cached=#{ca} out=#{ct}#{Color::RESET}"
      end

      resp[:content]
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
    # verify_observations
    # ---------------------------------------------------------------------------

    def verify_observations
      return unless @file_plan

      @file_plan[:modify].each do |path|
        next if @observations.any? { |o| o[:label] == path }

        Calvin::LOG.warn "verify: '#{path}' in modify plan but not read — forcing read"
        content = @github.get_file_content(path)
        unless content
          Calvin::LOG.warn "verify: '#{path}' not found in repo — skipping"
          next
        end
        Calvin.file_read(path, content.bytesize)
        record_observation("read_file", { "path" => path }, content.force_encoding("UTF-8"))
      end
    end

    # ---------------------------------------------------------------------------
    # Fase 2 — implement
    # ---------------------------------------------------------------------------

    def implement_phase(turns)
      Calvin.banner("IMPLEMENT", emoji: "✏️")
      ep = @usage_explore["prompt_tokens"]
      ec = @usage_explore["completion_tokens"]
      ca = @usage_explore["cached_tokens"]
      Calvin::LOG.info "explore summary  turns=#{turns}  in=#{ep} cached=#{ca} out=#{ec}  temp=#{@temp_implement}"

      active_retrieval = @retrieval_implement.chunks.any? ? @retrieval_implement : @retrieval_explore
      source_label     = @retrieval_implement.chunks.any? ? "implement" : "explore(fallback)"
      Calvin::LOG.info "rag source=#{source_label}  chunks=#{active_retrieval.chunks.size}"

      response = @mistral.complete_messages(
        build_implement_messages,
        temperature: @temp_implement
      )

      if response[:usage]
        pt = response[:usage]["prompt_tokens"].to_i
        ct = response[:usage]["completion_tokens"].to_i
        Calvin::LOG.info "#{Color::DIM}tokens  in=#{pt} out=#{ct}#{Color::RESET}"
      end

      Calvin.done("implement done  #{(response[:content].bytesize / 1024.0).round(1)} KB output")

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

    def build_implement_messages
      messages = []
      messages << { role: "system", content: build_implement_system }

      active_retrieval = @retrieval_implement.chunks.any? ? @retrieval_implement : @retrieval_explore
      chunks = active_retrieval.chunks

      if chunks.any?
        source = @retrieval_implement.chunks.any? ? "implement" : "explore (fallback)"
        rules_content = format_chunks_as_rules(chunks)
        messages << { role: "system", content: rules_content }
        Calvin::LOG.info "rules/#{source}  #{chunks.size} chunks  #{(rules_content.bytesize / 1024.0).round(1)} KB → second system message"
      else
        Calvin::LOG.info "rules: no chunks — skipping second system message"
      end

      messages << { role: "user", content: build_implement_user }
      messages
    end

    def format_chunks_as_rules(chunks)
      header = "## Architectural rules and project conventions\n" \
               "Apply ALL of the following without exception. " \
               "These override any general coding instincts."

      body = chunks.map.with_index(1) do |c, i|
        sim      = c["similarity"].to_f.round(3)
        src_type = c["source_type"] || "rule"
        path     = c["source_path"] || "unknown"
        "### #{i}. #{path} [#{src_type}, relevance=#{sim}]\n#{c['content']}"
      end.join("\n\n")

      "#{header}\n\n#{body}"
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
              when "grep"      then "grep #{args['pattern'].to_s.strip} in #{args['path'].to_s.strip}"
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
      },
      "grep" => ->(github, args) {
        pattern = args["pattern"].to_s
        path    = args["path"].to_s.strip
        github.grep_files(pattern, path)
      }
    }.freeze

    def dispatch_tool(tool, args)
      handler = TOOLS[tool]
      unless handler
        Calvin::LOG.warn "Unknown tool: #{tool}"
        return "ERROR: unknown tool '#{tool}'. Use: read_file, list_dir, grep, done."
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
