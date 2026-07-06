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
  # Logger con formatter leggibile:
  #   13:16:01  INFO  labels: rails, feature, calvin
  #   13:16:01  WARN  JSON parse failed
  LOG = Logger.new($stdout).tap do |l|
    l.progname = "calvin"
    l.formatter = proc do |severity, time, _progname, msg|
      ts    = time.strftime("%H:%M:%S")
      level = severity.ljust(4)
      "#{ts}  #{level}  #{msg}\n"
    end
  end

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

# Tutti i require_relative vengono DOPO la definizione di Calvin::CONFIG e Calvin::REPO
# perché alcuni moduli accedono a queste costanti a load-time.
#
# Ordine: primitivi → client → parser → flow components → flow → post-steps
require_relative "flow_result"
require_relative "mode_router"
require_relative "github_client"
require_relative "mistral_client"
require_relative "context_builder"
require_relative "file_parser"
require_relative "pr_body_builder"
require_relative "react_loop"
require_relative "commit_and_pr"
require_relative "explore_flow"
require_relative "rubocop_runner"
require_relative "rubocop_autocorrect"
require_relative "run_reporter"
require_relative "post_steps"
