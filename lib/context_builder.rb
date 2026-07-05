# frozen_string_literal: true
# Costruisce il prompt per i flussi Calvin.
#
# Priorità:
#   1. Label "calvin-auto-body" sull'issue
#      → usa title + body, ignora commenti (override esplicito)
#   2. Commento con marker <!-- agent-prompt -->
#      → comportamento standard, invariato
#   3. Fallback automatico: nessun commento agent-prompt trovato
#      → usa title + body con avviso
#
# Nei casi 1 e 3 viene preposto un avviso al prompt così è sempre
# chiaro da dove viene il contenuto.

require "octokit"

module Calvin
  class ContextBuilder
    AGENT_PROMPT_MARKER  = "<!-- agent-prompt -->"
    BODY_LABEL           = "calvin-auto-body"

    def self.build(issue, github_client:)
      new(issue, github_client).build
    end

    def initialize(issue, github_client)
      @issue         = issue
      @github_client = github_client
    end

    def build
      labels = @issue.labels.map(&:name)

      # Caso 1: label calvin-auto-body — usa title+body, ignora commenti
      if labels.include?(BODY_LABEL)
        Calvin::LOG.info "agent-prompt: label '#{BODY_LABEL}' presente, uso title+body (override)"
        return build_from_issue(override: true)
      end

      # Caso 2: commento con marker <!-- agent-prompt -->
      comments = @github_client.issue_comments(@issue)
      comment  = comments.find { |c| c.body.lstrip.start_with?(AGENT_PROMPT_MARKER) }

      if comment
        Calvin::LOG.info "agent-prompt: trovato commento ##{comment.id} (#{comment.body.bytesize} bytes)"
        return comment.body
      end

      # Caso 3: fallback automatico su title+body
      Calvin::LOG.info "agent-prompt: nessun commento trovato, fallback su title+body issue ##{@issue.number}"
      build_from_issue(override: false)
    end

    private

    def build_from_issue(override:)
      title = @issue.title.to_s.strip
      body  = @issue.body.to_s.strip

      content = [title, body].reject(&:empty?).join("\n\n")

      if content.empty?
        raise "Issue ##{@issue.number}: title e body vuoti — impossibile costruire il prompt."
      end

      Calvin::LOG.info "agent-prompt: title+body (#{content.bytesize} bytes, override=#{override})"

      warning = if override
        "⚠️ Prompt generato da title+body dell'issue ##{@issue.number} (label: #{BODY_LABEL})."
      else
        "⚠️ Prompt generato automaticamente da title+body dell'issue ##{@issue.number} (nessun commento agent-prompt trovato)."
      end

      "#{warning}\n#{"\u2500" * 72}\n\n#{content}"
    end
  end
end
