# frozen_string_literal: true
# Costruisce il contesto per entrambi i flussi (aider e comment).
#
# Cerca il commento con marker <!-- agent-prompt --> sull'issue e lo restituisce.
# Questo è il contratto unico: niente più file .calvin/, niente source_files.
#
# .build(issue, github) -> String (il prompt) | raise se non trovato

require "octokit"

module Calvin
  class ContextBuilder
    AGENT_PROMPT_MARKER = "<!-- agent-prompt -->"

    def self.build(issue, github_client:)
      new(issue, github_client).build
    end

    def initialize(issue, github_client)
      @issue         = issue
      @github_client = github_client
    end

    def build
      comments = @github_client.issue_comments(@issue)

      if comments.empty?
        raise "Nessun commento trovato sull'issue ##{@issue.number}."
      end

      comment = comments.find { |c| c.body.lstrip.start_with?(AGENT_PROMPT_MARKER) }

      if comment.nil?
        raise "Nessun commento con marker '#{AGENT_PROMPT_MARKER}' sull'issue ##{@issue.number}."
      end

      Calvin::LOG.info "agent-prompt: trovato commento ##{comment.id} (#{comment.body.bytesize} bytes)"
      comment.body
    end
  end
end
