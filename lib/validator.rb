# frozen_string_literal: true
# Calvin::Validator — esegue il codice generato PRIMA di aprire la PR.
#
# Prima di questa classe Calvin era open-loop: generava, committava, apriva PR e sperava che
# la CI del repo target fosse verde. Qui i file generati vengono materializzati nel clone
# locale e passati attraverso una ladder di gate, dal più economico al più costoso.
#
# Ladder (si ferma al primo rosso):
#   1. syntax        ruby -c su ogni .rb generato
#   2. rubocop       offese non autocorreggibili, con la config del repo target
#   3. structural    controlli deterministici su ciò che il prompt chiedeva "per favore"
#   4. zeitwerk      bin/rails zeitwerk:check          (solo level: full)
#   5. migrate       bin/rails db:migrate              (solo level: full)
#   6. focused_test  bin/rails test <path mirati>      (solo level: full)
#   7. full_test     bin/rails test                    (solo se gates.full_test: true)
#
# I gate 1–3 non richiedono nessun ambiente Rails e girano sempre.
#
# .call(files:, workspace:, github:, file_plan: nil, originals: {}, issue: nil)
#   → Calvin::Validator::Result(ok:, stage:, output:, failed_paths:)
#
# files:     [{ path:, content: }]  i file generati dal modello
# originals: { path => contenuto pre-modifica }  usato dal diff-guard
# file_plan: { modify:, create:, reference: }    usato dal gate file_plan vs output

require "open3"
require "shellwords"

module Calvin
  class Validator
    Result = Data.define(:ok, :stage, :output, :failed_paths) do
      def ok? = ok
      def red? = !ok
    end

    STAGES = %i[syntax rubocop structural zeitwerk migrate focused_test full_test].freeze
    FULL_ONLY_STAGES = %i[zeitwerk migrate focused_test full_test].freeze

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(files:, workspace:, github: nil, file_plan: nil, originals: {}, issue: nil,
                   profile: nil)
      @files     = Array(files)
      @workspace = workspace
      @github    = github
      @file_plan = file_plan || { modify: [], create: [], reference: [] }
      @originals = originals || {}
      @issue     = issue
      @profile   = profile || Calvin::ProjectProfile.default
      @config    = Calvin::CONFIG[:validation] || {}
    end

    def call
      return ok(:skipped, "no files to validate") if @files.empty?

      unless @workspace&.available?
        Calvin::LOG.warn "Validator: clone locale non disponibile (#{@workspace&.root}) — solo gate strutturali"
      end

      # L'ordine conta: gli originali vanno letti PRIMA di sovrascrivere il working tree,
      # altrimenti il diff-guard confronterebbe l'output del modello con se stesso.
      capture_missing_originals
      materialize if @workspace&.available?

      STAGES.each do |stage|
        next unless enabled?(stage)

        Calvin.section("validate: #{stage}")
        result = run_stage(stage)
        next if result.nil? # gate non applicabile in questo run

        if result.red?
          Calvin::LOG.warn "Validator: #{stage} ROSSO — #{result.failed_paths.join(', ')}"
          return result
        end

        Calvin::LOG.info "Validator: #{stage} ok"
      end

      ok(:all, "all enabled gates passed")
    end

    private

    # ── infrastruttura ─────────────────────────────────────────────────────────

    # CALVIN_VALIDATION_LEVEL permette al workflow di scegliere il livello per singolo run
    # senza modificare config/calvin.yml.
    def level
      env = ENV["CALVIN_VALIDATION_LEVEL"].to_s.strip
      return env unless env.empty?

      (@config[:level] || "static").to_s
    end

    def full? = level == "full"

    def enabled?(stage)
      return false if FULL_ONLY_STAGES.include?(stage) && !full?

      gates = @config[:gates] || {}
      gates.fetch(stage, true)
    end

    def ok(stage, output) = Result.new(ok: true, stage: stage, output: output, failed_paths: [])

    def red(stage, output, paths = []) = Result.new(ok: false, stage: stage, output: output.to_s, failed_paths: paths)

    def ruby_files = @files.select { |f| f[:path].to_s.end_with?(".rb") }

    # Il chiamante passa gli originali letti durante explore (sorgente preferita: è ciò che
    # il modello ha effettivamente visto). Per i file mancanti li legge dal repo, così il
    # diff-guard copre anche i file che il modello ha modificato senza averli letti.
    def capture_missing_originals
      @files.each do |f|
        path = f[:path].to_s
        next if @originals.key?(path)

        content = if @workspace&.available?
                    @workspace.read(path)
        elsif @github
                    @github.get_file_content(path)
        end
        @originals[path] = content if content
      end
    end

    # Scrive i file generati nel clone locale: da qui in poi i gate vedono il repo
    # target nello stato in cui sarebbe dopo il merge.
    def materialize
      @files.each { |f| @workspace.write(f[:path], f[:content]) }
      Calvin::LOG.info "Validator: #{@files.size} file materializzati in #{@workspace.root}"
    end

    def run_stage(stage)
      case stage
      when :syntax       then gate_syntax
      when :rubocop      then gate_rubocop
      when :structural   then gate_structural
      when :zeitwerk     then gate_shell(:zeitwerk, @profile.gate_command(:zeitwerk))
      when :migrate      then gate_shell(:migrate, @profile.gate_command(:migrate))
      when :focused_test then gate_focused_test
      when :full_test    then gate_shell(:full_test, @profile.test_command)
      end
    end

    def timeout = @config[:timeout] || 600

    # Esegue un comando nella root del repo target.
    def shell(command)
      return [false, "workspace non disponibile: impossibile eseguire `#{command}`"] unless @workspace&.available?

      out, status = Open3.capture2e(
        { "RAILS_ENV" => "test", "DISABLE_SPRING" => "1" },
        command, chdir: @workspace.root
      )
      [status.success?, out.to_s]
    rescue Errno::ENOENT => e
      [false, "comando non eseguibile: #{e.message}"]
    end

    # ── gate 1: syntax ─────────────────────────────────────────────────────────

    def gate_syntax
      rb = ruby_files
      return nil if rb.empty?

      failures = rb.filter_map do |f|
        out, status = Open3.capture2e("ruby", "-c", stdin_data: f[:content])
        next if status.success?

        "#{f[:path]}:\n#{out.strip}"
      end

      return ok(:syntax, "#{rb.size} file(s) sintatticamente validi") if failures.empty?

      red(:syntax, failures.join("\n\n"), failed_paths_from(failures))
    end

    # ── gate 2: rubocop ────────────────────────────────────────────────────────
    #
    # RubocopRunner autocorregge; qui interessano le offese che restano dopo l'autocorrect,
    # perché sono quelle che faranno rosso il job di lint nel repo target.
    def gate_rubocop
      rb = ruby_files
      return nil if rb.empty?
      return nil unless @github || @workspace&.available?

      # remaining_offenses autocorregge e poi rilegge: quello che resta è ciò che
      # RubocopAutocorrect non potrà sistemare, quindi ciò che farà rosso il lint del target.
      offenses = Calvin::RubocopRunner.remaining_offenses(files: rb, github: @github)
      return ok(:rubocop, "rubocop non eseguibile — gate saltato") if offenses.nil?
      return ok(:rubocop, "nessuna offesa residua") if offenses[:count].zero?

      red(:rubocop, offenses[:output], offenses[:paths])
    end

    # ── gate 3: structural ─────────────────────────────────────────────────────
    #
    # Ogni check qui era una richiesta in prosa dentro explore_system.md o
    # implement_system.md. Un check deterministico non dipende dall'attenzione del modello.
    def gate_structural
      problems = []
      problems.concat(check_diff_guard)
      problems.concat(check_file_plan_alignment)
      problems.concat(check_migration_timestamps)
      problems.concat(check_route_controllers)
      problems.concat(check_forbidden_patterns)

      return ok(:structural, "#{@files.size} file(s) conformi") if problems.empty?

      red(:structural, problems.map { |p| "- #{p[:message]}" }.join("\n"), problems.map { |p| p[:path] }.uniq)
    end

    # diff-guard: intercetta i file esistenti riscritti in modo mutilato.
    # È la rete contro il fallimento più costoso del formato whole-file — il modello che
    # "riassume" un file invece di riprodurlo.
    def check_diff_guard
      guard   = @config[:diff_guard] || {}
      markers = guard[:ellipsis_markers] || []
      ratio   = guard[:max_shrink_ratio] || 0.25
      problems = []

      @files.each do |f|
        path     = f[:path].to_s
        original = @originals[path]
        content  = f[:content].to_s

        # 1. marker di elisione — valgono anche sui file nuovi: "# ... rest of file" finisce su disco
        markers.each do |marker|
          next unless content.match?(/^\s*#.*#{Regexp.escape(marker)}/i)

          problems << { path: path, message: "#{path}: marker di elisione «#{marker}» nel contenuto — il file sarebbe salvato incompleto" }
        end

        next if original.nil? || original.empty?

        # 2. shrink oltre soglia
        old_lines = original.lines.size
        new_lines = content.lines.size
        if old_lines.positive? && new_lines < old_lines * (1 - ratio)
          problems << { path: path, message: "#{path}: da #{old_lines} a #{new_lines} righe (-#{(100 - new_lines * 100.0 / old_lines).round}%) — possibile perdita di codice esistente" }
        end

        # 3. definizioni scomparse
        missing = missing_definitions(original, content)
        if missing.any?
          problems << { path: path, message: "#{path}: definizioni presenti nell'originale e assenti nell'output: #{missing.first(8).join(', ')}" }
        end
      end

      problems
    end

    DEFINITION_PATTERNS = [
      /^\s*def\s+([a-zA-Z_][\w?!=]*)/,
      /^\s*([A-Z][A-Z0-9_]+)\s*=/,
      /^\s*(?:has_many|has_one|belongs_to|has_and_belongs_to_many)\s+:(\w+)/,
      /^\s*scope\s+:(\w+)/
    ].freeze

    def missing_definitions(original, content)
      extract = lambda do |src|
        DEFINITION_PATTERNS.flat_map do |pattern|
          src.lines.filter_map { |line| line[pattern, 1] }
        end.to_set
      end

      (extract.call(original) - extract.call(content)).to_a.sort
    end

    # Ogni FILE block deve essere nel piano e ogni path del piano deve avere un blocco.
    # Prima le divergenze producevano commit parziali silenziosi.
    def check_file_plan_alignment
      planned = (Array(@file_plan[:modify]) + Array(@file_plan[:create])).map(&:to_s)
      return [] if planned.empty?

      produced = @files.map { |f| f[:path].to_s }
      problems = []

      (produced - planned).each do |path|
        problems << { path: path, message: "#{path}: FILE block fuori dal piano (non è in modify né in create)" }
      end

      (planned - produced).each do |path|
        problems << { path: path, message: "#{path}: dichiarato nel piano ma nessun FILE block prodotto" }
      end

      problems
    end

    # Una migration con timestamp inferiore a una esistente non viene mai eseguita da
    # db:migrate su un ambiente già migrato: bug silenzioso in produzione.
    def check_migration_timestamps
      new_migrations = @files.map { |f| f[:path].to_s }.select { |p| p.start_with?("db/migrate/") }
      return [] if new_migrations.empty?

      existing = existing_migration_versions
      floor    = existing.max
      problems = []

      new_migrations.each do |path|
        version = File.basename(path)[/\A(\d{14})_/, 1]
        unless version
          problems << { path: path, message: "#{path}: nome migration senza timestamp a 14 cifre" }
          next
        end

        if floor && version <= floor && !existing.include?(version)
          problems << { path: path, message: "#{path}: timestamp #{version} <= ultima migration esistente #{floor} — non verrebbe eseguita" }
        end
      end

      problems
    end

    def existing_migration_versions
      entries = if @workspace&.available?
                  @workspace.list("db/migrate")
      else
                  @github ? @github.list_directory("db/migrate") : []
      end
      generated = @files.map { |f| File.basename(f[:path].to_s) }
      entries.reject { |e| generated.include?(e) }.filter_map { |e| e[/\A(\d{14})_/, 1] }
    end

    # Ogni route aggiunta deve avere un controller: era una regola in prosa
    # ("A route without a controller is a deploy-breaking error"), ora è un check.
    ROUTE_LINE = /^\s*(get|post|put|patch|delete)\s+['"]?([^'",\s]+)['"]?.*?to:\s*['"]([\w\/]+)#(\w+)['"]/

    def check_route_controllers
      routes_file = @files.find { |f| f[:path].to_s == "config/routes.rb" }
      return [] unless routes_file

      original = @originals["config/routes.rb"].to_s
      problems = []

      routes_file[:content].to_s.lines.each do |line|
        match = line.match(ROUTE_LINE)
        next unless match

        next if original.include?(line.strip) # route preesistente

        controller_path = "app/controllers/#{match[3]}_controller.rb"
        next if produced_paths.include?(controller_path)
        next if file_exists_in_repo?(controller_path)

        problems << { path: "config/routes.rb", message: "route `#{match[1]} #{match[2]}` punta a #{match[3]}##{match[4]} ma #{controller_path} non esiste e non è stato generato" }
      end

      problems
    end

    # Pattern che il progetto target dichiara vietati in `.calvin/project.yml`.
    #
    # Prima qui era compilata una regola di synca ("niente `validates` sotto app/models — i
    # model sono strutture dati"): una convenzione di UN progetto dentro il motore, che su
    # qualunque altra applicazione Rails avrebbe bocciato codice corretto. Ora la regola la
    # dichiara il progetto, e Calvin la applica senza saperla.
    def check_forbidden_patterns
      @files.flat_map do |f|
        path = f[:path].to_s
        @profile.forbidden_matches(path, f[:content]).map { |message| { path: path, message: message } }
      end
    end

    def produced_paths = @produced_paths ||= @files.map { |f| f[:path].to_s }

    def file_exists_in_repo?(path)
      return @workspace.exist?(path) if @workspace&.available?
      return false unless @github

      !@github.get_file_content(path).nil?
    end

    # ── gate 6: focused_test ───────────────────────────────────────────────────
    #
    # Esegue solo i test dei layer toccati: la suite completa costa minuti e sta dietro
    # gates.full_test.
    def gate_focused_test
      paths = focused_test_paths
      return nil if paths.empty?

      command = @profile.test_command
      success, output = shell("#{command} #{paths.map { |p| Shellwords.escape(p) }.join(' ')}")
      return ok(:focused_test, "#{paths.size} test file(s) verdi") if success

      red(:focused_test, output, paths)
    end

    # Da app/services/foo_service.rb ricava test/services/foo_service_test.rb se esiste.
    # La derivazione la definisce il progetto (`test.path_map`), non Calvin: un progetto a
    # RSpec mappa su spec/…_spec.rb e qui non cambia niente.
    def focused_test_paths
      @files.filter_map do |f|
        candidate = @profile.test_path_for(f[:path].to_s)
        candidate if candidate && @workspace&.exist?(candidate)
      end.uniq
    end

    # command nil = il progetto non espone questo gate (es. nessun zeitwerk:check):
    # va saltato, non fatto fallire.
    def gate_shell(stage, command)
      if command.nil?
        Calvin::LOG.info "Validator: #{stage} non dichiarato dal profilo — gate saltato"
        return nil
      end

      success, output = shell(command)
      return ok(stage, output.lines.last.to_s.strip) if success

      red(stage, output, produced_paths)
    end

    def failed_paths_from(failures)
      failures.filter_map { |f| f[/\A([^\s:]+):/, 1] }
    end
  end
end
