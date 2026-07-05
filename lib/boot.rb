# frozen_string_literal: true
# Bootstrap Calvin — caricato una sola volta da bin/calvin.rb.
# Tutti i require vivono qui. bin/calvin.rb non sa nulla di gem o dipendenze.
#
# Convenzione:
#   - Gem di terze parti: require "nome"
#   - Stdlib Ruby:        require "nome"  (stesso stile, stessa lista)
#   - File interni:       require_relative nei singoli file NON usato
#                         (tutti i moduli Calvin sono caricati da qui)

# Gem
require "dry/monads"
require "dry/transaction"
require "octokit"
require "base64"

# Stdlib
require "logger"
require "yaml"
require "open3"
require "json"
require "csv"
require "fileutils"
require "tmpdir"

# Calvin::CONFIG deve essere definito PRIMA di qualsiasi require_relative,
# perché le costanti di classe nei file caricati vengono evaluate
# immediatamente al momento del require.
module Calvin
  CONFIG = YAML.safe_load_file(
    File.expand_path("../../config/calvin.yml", __FILE__),
    symbolize_names: true
  ).freeze

  # Radici dei repo per stack — lette da calvin.yml, non hardcodate.
  REPO_ROOTS = (CONFIG.dig(:repo_roots) || {}).transform_keys(&:to_s).freeze
end

require_relative "github_client"
require_relative "context_builder"
require_relative "file_parser"
require_relative "mistral_client"
require_relative "commit_and_pr"
require_relative "test_runner"
require_relative "test_fix_prompt_builder"
require_relative "test_fix_loop"
require_relative "explore_flow"
require_relative "run_reporter"
require_relative "rubocop_autocorrect"
require_relative "pr_body_builder"
require_relative "react_loop"

module Calvin
  REPO  = ENV.fetch("GITHUB_REPOSITORY")
  MODEL = ENV.fetch("CALVIN_MODEL", "codestral-latest")
  LOG   = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end
end
