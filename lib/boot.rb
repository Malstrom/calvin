# frozen_string_literal: true
# Bootstrap Calvin — caricato una sola volta da bin/calvin.rb.
# Tutti i require vivono qui. bin/calvin.rb non sa nulla di gem o dipendenze.

require "dry/monads"
require "octokit"
require "base64"
require "logger"
require "yaml"

require_relative "github_client"
require_relative "context_builder"
require_relative "mistral_client"
require_relative "file_parser"
require_relative "commit_and_pr"
require_relative "implement_flow"
require_relative "explore_flow"
require_relative "ci_fix_flow"
require_relative "run_reporter"
require_relative "rubocop_autocorrect"
require_relative "test_output_parser"
require_relative "issue_commenter"
require_relative "pr_body_builder"
require_relative "fix_prompt_builder"
require_relative "test_context_injector"
require_relative "react_loop"

module Calvin
  CONFIG = YAML.safe_load_file(
    File.expand_path("../../config/calvin.yml", __FILE__),
    symbolize_names: true
  ).freeze

  REPO  = ENV.fetch("GITHUB_REPOSITORY")
  MODEL = ENV.fetch("CALVIN_MODEL", "codestral-latest")
  LOG   = Logger.new($stdout).tap do |l|
    l.formatter = proc { |sev, _, _, msg| "[calvin] #{sev}: #{msg}\n" }
  end

  REPO_ROOTS = {
    "rails"   => "backend/api",
    "flutter" => "frontend/mobile"
  }.freeze
end
