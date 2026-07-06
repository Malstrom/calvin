# frozen_string_literal: true
# Bootstrap Calvin — caricato una sola volta da bin/calvin.rb.
# Tutti i require vivono qui. bin/calvin.rb non sa nulla di gem o dipendenze.

require "dry/monads"
require "octokit"
require "base64"
require "logger"
require "yaml"

# Calvin::CONFIG deve essere definito PRIMA di qualsiasi require_relative,
# perché le costanti di classe nei file caricati vengono evaluate immediatamente.
module Calvin
  CONFIG = YAML.safe_load_file(
    File.expand_path("../../config/calvin.yml", __FILE__),
    symbolize_names: true
  ).freeze

  # Lette da CONFIG — nessun valore hardcodato nel codice Ruby.
  CONVENTIONS_PATH = CONFIG.dig(:repo, :conventions_path).freeze
  REPO_ROOTS       = (CONFIG.dig(:repo, :roots) || {}).transform_keys(&:to_s).freeze
end

require_relative "github_client"
require_relative "context_builder"
require_relative "file_parser"
require_relative "mistral_client"
require_relative "commit_and_pr"
require_relative "explore_flow"
require_relative "run_reporter"
require_relative "rubocop_autocorrect"
require_relative "issue_commenter"
require_relative "pr_body_builder"
require_relative "react_loop"
require_relative "mode_router"

module Calvin
  REPO  = ENV.fetch("GITHUB_REPOSITORY")
  MODEL = ENV.fetch("CALVIN_MODEL", CONFIG.dig(:model, :default) || "codestral-latest")
  LOG   = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end
end
