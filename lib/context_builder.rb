# frozen_string_literal: true
# Costruisce il prompt da passare al ReActLoop.
#
# Logica:
#   - Legge title + body dell'issue
#   - Ritorna una stringa pronta come user-message per il modello

module Calvin
  module ContextBuilder
    extend self

    def build(issue, github_client: nil)
      parts = []
      parts << "## Issue ##{issue.number}: #{issue.title}"
      parts << issue.body.to_s.strip unless issue.body.to_s.strip.empty?
      parts.join("\n\n")
    end
  end
end
