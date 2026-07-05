# frozen_string_literal: true
# Posta un commento sull'issue del repo target.
#
# Non usa più marker né logica di upsert — non legge il body dell'issue
# e non dipende da nessuna convezione legacy. Solo title + body della issue
# sono usati come contesto da Calvin; i commenti passati sono ignorati.
#
# Uso:
#   Calvin::IssueCommenter.post(github: client, issue: issue, message: "...")

module Calvin
  module IssueCommenter
    def self.post(github:, issue:, message:)
      github.add_issue_comment(issue.number, message)
    rescue => e
      Calvin::LOG.warn "IssueCommenter failed: #{e.class} — #{e.message}"
    end
  end
end
