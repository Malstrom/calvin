# frozen_string_literal: true
# Bootstrap Calvin — caricato come primo require da bin/calvin.rb.
# Imposta costanti globali, logger, e dipendenze.

require "yaml"
require "logger"
require "dry/monads"
require "dry/transaction"

require_relative "flow_result"
require_relative "mode_router"
require_relative "github_client"
require_relative "mistral_client"
require_relative "rubocop_autocorrect"
require_relative "run_reporter"

module Calvin
  # Logger
  LOG = Logger.new($stdout).tap { |l| l.progname = "calvin" }

  # Config centralizzata — unica fonte di verità per tutti i parametri.
  CONFIG = YAML.load_file(
    File.expand_path("../../config/calvin.yml", __FILE__), symbolize_names: true
  ).freeze

  # Modello attivo — da env o config.
  MODEL = ENV.fetch("CALVIN_MODEL", CONFIG.dig(:model, :default) || "codestral-latest").freeze

  # Roots per repo target (stack => path relativo).
  REPO_ROOTS = (CONFIG.dig(:repo, :roots) || {}).transform_keys(&:to_s).freeze
end
