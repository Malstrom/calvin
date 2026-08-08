# frozen_string_literal: true
# Calvin::ProjectProfile — tutto ciò che Calvin sa di UN progetto target.
#
# Prima di questa classe la conoscenza del progetto era sparsa in tre posti diversi, tutti
# dentro Calvin: `repo.roots` e `project.*` in config/calvin.yml, le domain rules dentro
# config/prompts/rails/*.md, e `check_model_validations` dentro validator.rb. Calvin poteva
# quindi lavorare su un solo repo — synca — e ogni convenzione che cambiava era una modifica
# al motore.
#
# Qui il rapporto si inverte: il profilo vive NEL repo target, in `.calvin/project.yml`, e
# Calvin lo legge a runtime. Attaccare Calvin a un nuovo progetto Rails non richiede nessuna
# modifica a Calvin.
#
#   .calvin/project.yml      questo file — layout, comandi, gate, pattern vietati
#   .calvin/conventions.md   le regole sempre attive, iniettate nel system prompt
#
# Se `.calvin/project.yml` non esiste, il profilo cade su default Rails generici (app in root,
# Minitest, `bin/rails test`) più il fallback legacy `repo.roots` per label, che tiene in piedi
# i target che non hanno ancora migrato.
#
# Uso:
#   root    = Calvin::Workspace.new(repo_root: "")        # radice del repo, non dell'app
#   profile = Calvin::ProjectProfile.load(workspace: root, github: github, labels: labels)
#   profile.app_root            # => "backend/api" | ""
#   profile.test_path_for("app/services/foo.rb")  # => "test/services/foo_test.rb" | nil
#   profile.gate_command(:migrate)                 # => "bin/rails db:migrate"
#   profile.forbidden_matches("app/models/user.rb", content)  # => [messaggi]
#   profile.conventions         # => contenuto di .calvin/conventions.md | nil

require "yaml"

module Calvin
  class ProjectProfile
    PROFILE_PATH     = ".calvin/project.yml"
    CONVENTIONS_PATH = ".calvin/conventions.md"

    # Default di un'applicazione Rails standard: app in root, Minitest, comandi rails di serie.
    # Un progetto che rispetta queste convenzioni non ha bisogno di scrivere project.yml.
    DEFAULT_TEST_COMMAND = "bin/rails test"
    DEFAULT_PATH_MAP     = [{ from: 'app/(.*)\.rb', to: 'test/\1_test.rb' }].freeze
    DEFAULT_GATES        = { zeitwerk: "bin/rails zeitwerk:check", migrate: "bin/rails db:migrate" }.freeze
    DEFAULT_INDEX        = {
      include: ["app/**/*.rb", "lib/**/*.rb", "config/routes.rb", "test/**/*.rb"],
      exclude: ["db/schema.rb", "**/vendor/**"]
    }.freeze

    attr_reader :app_root, :conventions, :source

    # workspace: Calvin::Workspace sulla RADICE del repo (repo_root: ""), non sull'app.
    #            `.calvin/` sta alla radice, e app_root è proprio ciò che stiamo per scoprire.
    # github:    fallback quando il clone locale non è disponibile.
    # labels:    label della issue — usate solo dal fallback legacy repo.roots.
    def self.load(workspace: nil, github: nil, labels: [])
      raw = read(PROFILE_PATH, workspace, github)

      data = if raw
               parse(raw)
      else
               {}
      end

      new(
        data:        data,
        conventions: read(CONVENTIONS_PATH, workspace, github),
        labels:      labels,
        source:      raw ? :project_yml : :defaults
      )
    end

    def self.parse(raw)
      YAML.safe_load(raw, symbolize_names: true, aliases: true) || {}
    rescue Psych::Exception => e
      Calvin::LOG.warn "ProjectProfile: #{PROFILE_PATH} non parsabile (#{e.message}) — uso i default"
      {}
    end
    private_class_method :parse

    def self.read(path, workspace, github)
      content = workspace&.available? ? workspace.read(path) : nil
      content || github&.get_file_content(path)
    rescue => e
      Calvin::LOG.warn "ProjectProfile: lettura di #{path} fallita (#{e.message})"
      nil
    end
    private_class_method :read

    # Profilo generico condiviso, per i call site che non ne ricevono uno (test unitari,
    # Validator invocato senza contesto di flow). Memoizzato: costruirlo a ogni chiamata
    # riempirebbe i log di righe identiche.
    def self.default
      @default ||= new
    end

    def initialize(data: {}, conventions: nil, labels: [], source: :defaults)
      @data        = data || {}
      @conventions = truncate_conventions(conventions)
      @source      = source
      @app_root    = resolve_app_root(labels)

      log_summary
    end

    # ── test ───────────────────────────────────────────────────────────────────

    def test_framework = test_config[:framework].to_s.empty? ? "minitest" : test_config[:framework].to_s

    def test_command = test_config[:command].to_s.empty? ? DEFAULT_TEST_COMMAND : test_config[:command].to_s

    # Deriva il path del test dal path del sorgente applicando la prima regola che matcha.
    # Prima questa derivazione esisteva in due copie divergenti: TestWriter::TESTABLE_DIRS
    # (solo services/contracts/jobs) e Validator#focused_test_paths (tutto app/).
    #
    #   "app/services/foo.rb" → "test/services/foo_test.rb"
    # Ritorna nil se nessuna regola matcha: il file non è testabile per questo progetto.
    def test_path_for(source_path)
      path = source_path.to_s
      path_map.each do |rule|
        from = rule[:from].to_s
        to   = rule[:to].to_s
        next if from.empty? || to.empty?

        begin
          regex = Regexp.new("\\A#{from}\\z")
        rescue RegexpError => e
          Calvin::LOG.warn "ProjectProfile: regex test.path_map non valida '#{from}' (#{e.message}) — regola saltata"
          next
        end

        return path.sub(regex, to) if path.match?(regex)
      end
      nil
    end

    # ── gate ───────────────────────────────────────────────────────────────────

    # Comando shell per un gate della ladder, o nil se il progetto non lo espone.
    # Un gate senza comando viene saltato invece di fallire: non tutti i progetti Rails
    # hanno zeitwerk:check o un db da migrare.
    def gate_command(stage)
      key   = stage.to_sym
      value = gates.fetch(key) { DEFAULT_GATES[key] }
      value.to_s.strip.empty? ? nil : value.to_s
    end

    # ── pattern vietati ────────────────────────────────────────────────────────

    # Sostituisce check_model_validations, che aveva la regola di synca
    # ("i model sono strutture dati, niente validates") compilata dentro il Validator.
    #
    # Ritorna i messaggi delle regole violate da questo file.
    def forbidden_matches(path, content)
      forbidden_patterns.filter_map do |rule|
        glob    = rule[:paths].to_s
        pattern = rule[:pattern].to_s
        next if glob.empty? || pattern.empty?
        next unless path_matches?(glob, path.to_s)

        begin
          regex = Regexp.new(pattern)
        rescue RegexpError => e
          Calvin::LOG.warn "ProjectProfile: regex forbidden_patterns non valida '#{pattern}' (#{e.message}) — regola saltata"
          next
        end

        next unless content.to_s.match?(regex)

        rule[:message].to_s.empty? ? "#{path}: viola il pattern vietato /#{pattern}/" : "#{path}: #{rule[:message]}"
      end
    end

    def forbidden_patterns = Array(@data[:forbidden_patterns])

    # ── indicizzazione (usata dallo step 2 — indice del codice nel DB vettoriale) ──

    def index_include = Array(index_config[:include]).map(&:to_s).then { |v| v.empty? ? DEFAULT_INDEX[:include] : v }

    def index_exclude = Array(index_config[:exclude]).map(&:to_s).then { |v| v.empty? ? DEFAULT_INDEX[:exclude] : v }

    # ── introspezione ──────────────────────────────────────────────────────────

    def defaults? = @source == :defaults

    def conventions? = !@conventions.nil? && !@conventions.empty?

    private

    def test_config  = @data[:test]  || {}
    def gates        = @data[:gates] || {}
    def index_config = @data[:index] || {}

    def path_map
      configured = Array(test_config[:path_map])
      configured.empty? ? DEFAULT_PATH_MAP : configured
    end

    # `**` deve attraversare le directory come si aspetta chi scrive "app/models/**",
    # quindi niente FNM_PATHNAME.
    def path_matches?(glob, path)
      File.fnmatch?(glob, path, File::FNM_EXTGLOB)
    end

    # app_root dal profilo. Il fallback su repo.roots per label tiene in piedi i target che
    # non hanno ancora `.calvin/project.yml` — va rimosso quando tutti avranno migrato.
    def resolve_app_root(labels)
      declared = @data[:app_root]
      return declared.to_s.strip.delete_suffix("/") unless declared.nil?

      legacy = Calvin::REPO_ROOTS.find { |label, _| Array(labels).include?(label) }&.last
      if legacy
        Calvin::LOG.warn "ProjectProfile: #{PROFILE_PATH} assente — app_root='#{legacy}' dal fallback legacy repo.roots. " \
                         "Aggiungi #{PROFILE_PATH} al repo target."
        return legacy.to_s
      end

      ""
    end

    def truncate_conventions(content)
      return nil if content.nil?

      text  = content.to_s
      limit = Calvin::CONFIG.dig(:conventions, :max_bytes) || 8192
      return text if text.bytesize <= limit

      Calvin::LOG.warn "ProjectProfile: #{CONVENTIONS_PATH} è #{text.bytesize}B, troncato a #{limit}B"
      "#{text.byteslice(0, limit)}\n\n… (convenzioni troncate a #{limit} byte)"
    end

    def log_summary
      Calvin::LOG.info "profile: #{@source}  app_root=#{@app_root.empty? ? '(root)' : @app_root}  " \
                       "test=#{test_framework}  conventions=#{conventions? ? "#{@conventions.bytesize}B" : 'none'}  " \
                       "forbidden=#{forbidden_patterns.size}"
    end
  end
end
