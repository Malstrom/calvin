# frozen_string_literal: true
# Posta commenti sulle issue del repo target.
#
# Usa il marker <!-- calvin-comment --> per evitare duplicati:
# se un commento con lo stesso marker + type esiste già, lo aggiorna.
#
# Uso:
#   Calvin::IssueCommenter.post(github: client, issue: issue, message: "...")

module Calvin
  module IssueCommenter
    MARKER = "<!-- calvin-comment -->"

    def self.post(github:, issue:, message:)
      body = "#{MARKER}\n#{message}"
      github.post_status(issue, message)
    rescue => e
      Calvin::LOG.warn "IssueCommenter failed: #{e.class} — #{e.message}"
    end
  end
end
