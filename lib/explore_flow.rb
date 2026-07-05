# frozen_string_literal: true
# Flusso autonomo Calvin (calvin-auto):
#   1. Costruisce il prompt dall'issue (titolo + body)
#   2. Avvia ReActLoop: il modello esplora il repo e decide cosa scrivere
#   3. Parsea i FILE: blocks e il PR_BODY block dalla risposta finale
#   4. Commit atomico + apre PR con description e token report nel body
#
# Non usa ContextBuilder: non c'è agent-prompt scritto da Igor.
# Il modello guida da solo l'esplorazione.
#
# .run → Success(pr_url) | Failure(msg)
# .last_usage → Hash | nil  (disponibile dopo .run, per RunReporter)

require "dry/monads"
require_relative "file_parser"
require_relative "react_loop"
require_relative "commit_and_pr"

module Calvin
  class ExploreFlow
    include Dry::Monads[:result]
    include CommitAndPr

    attr_reader :last_usage

    def initialize(github, issue)
      @github     = github
      @issue      = issue
      @last_usage = nil
    end

    def run
      prompt = build_issue_prompt
      Calvin::LOG.info "ExploreFlow avviato per issue ##{@issue.number}"

      result = ReActLoop.new(@github, prompt).run
      Calvin::LOG.info "ReActLoop terminato in #{result[:turns]} turn(s)"

      files = FileParser.parse(result[:content])
      Calvin::LOG.info "parsed #{files.size} file(s) da ReActLoop"

      return Failure("ExploreFlow: nessun FILE: block prodotto dal modello") if files.empty?

      description = FileParser.parse_pr_body(result[:content])
      @last_usage = result[:usage]
      Calvin::LOG.info(description ? "PR body estratto (#{description.bytesize} bytes)" : "PR body non trovato nella risposta")

      pr_url = commit_and_open_pr(files, issue: @issue, branch_prefix: "auto",
                                         usage: @last_usage, description: description)
      Calvin::LOG.info "##{@issue.number} done — PR: #{pr_url}"
      Success(pr_url)
    rescue StandardError => e
      Failure("ExploreFlow error: #{e.message}")
    end

    private

    def build_issue_prompt
      top_level = @github.list_directory("").join(", ") rescue "(non disponibile)"

      <<~PROMPT
        # Task: #{@issue.title}

        #{@issue.body.to_s.strip}

        ## Struttura top-level del repo
        #{top_level}

        Esplora il repo, leggi i file rilevanti, poi implementa il task.
      PROMPT
    end
  end
end
