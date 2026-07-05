# frozen_string_literal: true
# Costruisce il prompt per il ReActLoop.
#
# Unica fonte: title + body dell'issue.
# Nessuna logica su label o commenti.

module Calvin
  class ContextBuilder
    def self.build(issue, github_client: nil)
      title   = issue.title.to_s.strip
      body    = issue.body.to_s.strip
      content = [title, body].reject(&:empty?).join("\n\n")

      raise "Issue ##{issue.number}: title e body vuoti." if content.empty?

      Calvin::LOG.info "context_builder: issue ##{issue.number} (#{content.bytesize} bytes)"
      content
    end
  end
end
