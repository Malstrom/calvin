# frozen_string_literal: true
# Bootstrap Calvin — caricato come primo require da bin/calvin.rb.
# Imposta costanti globali, logger, e dipendenze.

require "yaml"
require "logger"
require "csv"
require "octokit"
require "dry/monads"
require "dry/transaction"

module Calvin
  # Logger
  LOG = Logger.new($stdout).tap { |l| l.progname = "calvin" }

  # Config centralizzata — unica fonte di verità per tutti i parametri.
  # DEVE essere definita prima di qualsiasi require_relative che usa Calvin::CONFIG.
  CONFIG = YAML.load_file(
    File.expand_path("../../config/calvin.yml", __FILE__), symbolize_names: true
  ).freeze

  # Modello attivo — da env o config.
  MODEL = ENV.fetch("CALVIN_MODEL", CONFIG.dig(:model, :default) || "codestral-latest").freeze

  # Repo target — formato "owner/repo".
  # CALVIN_TARGET_REPO è impostato esplicitamente nel workflow Calvin.
  # Fallback a GITHUB_REPOSITORY per compatibilità (es. run locali).
  REPO = ENV.fetch("CALVIN_TARGET_REPO") { ENV.fetch("GITHUB_REPOSITORY") }.freeze

  # Roots per repo target (stack => path relativo).
  REPO_ROOTS = (CONFIG.dig(:repo, :roots) || {}).transform_keys(&:to_s).freeze
end

# Tutti i require_relative vengono DOPO la definizione di Calvin::CONFIG
# perché alcuni moduli accedono a CONFIG a load-time (es. mode_router.rb).
require_relative "flow_result"
require_relative "mode_router"
require_relative "github_client"
require_relative "mistral_client"
require_relative "rubocop_runner"
require_relative "rubocop_autocorrect"
require_relative "run_reporter"
require_relative "post_steps"
