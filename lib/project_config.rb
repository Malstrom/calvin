# frozen_string_literal: true
# Calvin::ProjectConfig — la configurazione che appartiene al progetto, non al motore.
#
# Prima di questa classe Calvin conteneva lo stato di synca: rag.target_repo,
# project.fixtures_dir, project.test_helper_path, repo.roots. Aggiungere un secondo
# progetto significava modificare e ridistribuire Calvin. Ora ogni target porta la propria
# configurazione in `.calvin/calvin.yml`, e `config/calvin.yml` di Calvin tiene solo i
# default del motore.
#
# Il merge è profondo e il target vince sempre sui default, ma NON può toccare le chiavi
# del motore (react, sampling, http, mistral, pricing, repair): un progetto non deve poter
# alzare il budget di spesa o cambiare il modello di Calvin.
#
# Formato di .calvin/calvin.yml nel repo target:
#
#   stack: rails
#   root: backend/api            # dove vive l'applicazione dentro il repo
#   validation:
#     level: full
#   project:
#     fixtures_dir: test/fixtures
#     test_helper_path: test/test_helper.rb
#
# .load(workspace, defaults:) → Hash (config effettiva)
#
# Nota: la config del target viene letta dal clone locale. Senza clone si usano i default,
# ed è un caso da segnalare, non da nascondere.

require "yaml"

module Calvin
  module ProjectConfig
    PATH = ".calvin/calvin.yml"

    # Chiavi che restano di competenza esclusiva di Calvin: un progetto non le sovrascrive.
    ENGINE_ONLY = %i[react sampling http mistral model pricing repair routing].freeze

    # Chiavi che il target può definire.
    PROJECT_KEYS = %i[stack root validation project rag workspace test_generation].freeze

    # root_workspace: workspace di fallback (repo_root: "") se il file non si trova nella
    # root primaria — necessario perché la root "giusta" per .calvin/ dipende dal layout
    # del repo target, che è esattamente ciò che questo file dichiara.
    def self.load(workspace, root_workspace: nil, defaults: Calvin::CONFIG)
      raw = read(workspace) || (root_workspace && read(root_workspace))
      return defaults if raw.nil?

      overrides = sanitize(raw)
      if overrides.empty?
        Calvin::LOG.warn "ProjectConfig: #{PATH} presente ma senza chiavi utilizzabili"
        return defaults
      end

      Calvin::LOG.info "ProjectConfig: #{PATH} → override su #{overrides.keys.join(', ')}"
      deep_merge(defaults, overrides)
    end

    # La root dell'applicazione dentro il repo target.
    # Ordine: .calvin/calvin.yml → repo.roots per stack (compatibilità) → "".
    def self.root_for(config, stack:)
      explicit = config[:root]
      return explicit.to_s unless explicit.nil? || explicit.to_s.empty?

      (config.dig(:repo, :roots, stack.to_sym) || "").to_s
    end

    def self.read(workspace)
      return nil unless workspace&.available?

      raw = workspace.read(PATH)
      return nil if raw.nil? || raw.strip.empty?

      parsed = YAML.safe_load(raw, symbolize_names: true)
      parsed.is_a?(Hash) ? parsed : nil
    rescue Psych::SyntaxError => e
      Calvin::LOG.warn "ProjectConfig: #{PATH} non è YAML valido (#{e.message}) — uso i default"
      nil
    rescue => e
      Calvin::LOG.warn "ProjectConfig: lettura di #{PATH} fallita — #{e.class}: #{e.message}"
      nil
    end
    private_class_method :read

    def self.sanitize(raw)
      rejected = raw.keys & ENGINE_ONLY
      if rejected.any?
        Calvin::LOG.warn "ProjectConfig: chiavi del motore ignorate in #{PATH}: #{rejected.join(', ')}"
      end

      raw.slice(*PROJECT_KEYS)
    end
    private_class_method :sanitize

    def self.deep_merge(base, overrides)
      base.merge(overrides) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end
  end
end
