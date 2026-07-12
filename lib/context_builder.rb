# frozen_string_literal: true
# Costruisce il prompt utente per il ReActLoop.
#
# Fonti:
#   1. title + body dell'issue, con header espliciti # Task / ## Description
#   2. NEXT_MIGRATION_VERSION (letto dal repo target)
#
# Nota: il retrieval RAG è responsabilità di ExploreFlow (step retrieve_context),
# non di questo builder.

module Calvin
  class ContextBuilder
    MIGRATIONS_PATH = "db/migrate"

    def self.build(issue, github_client: nil)
      title = issue.title.to_s.strip
      body  = issue.body.to_s.strip

      raise "Issue ##{issue.number}: title e body vuoti." if title.empty? && body.empty?

      Calvin::LOG.info "--- issue ##{issue.number} context ---"
      Calvin::LOG.info "  title : #{title}"
      Calvin::LOG.info "  body  : #{body.empty? ? '(vuoto)' : body[0..120].gsub("\n", " ")}"
      Calvin::LOG.info "  bytes : #{(title + body).bytesize}"

      parts = ["# Task: #{title}"]
      parts << "## Description\n\n#{body}" unless body.empty?
      content = parts.join("\n\n")

      if github_client
        next_version = next_migration_version(github_client)
        content = "NEXT_MIGRATION_VERSION: #{next_version}\n\n#{content}"
        Calvin::LOG.info "  migration_version : #{next_version}"
      end

      content
    end

    def self.next_migration_version(github_client)
      entries = github_client.list_directory(MIGRATIONS_PATH)
      timestamps = entries
        .map    { |f| f.match(/\A(\d{14})_/)&.captures&.first }
        .compact
        .sort

      if timestamps.any?
        last = timestamps.last.to_i
        (last + 1).to_s
      else
        Time.now.utc.strftime("%Y%m%d%H%M%S")
      end
    rescue => e
      Calvin::LOG.warn "context_builder: impossibile leggere migrazioni (#{e.message}) — uso Time.now"
      Time.now.utc.strftime("%Y%m%d%H%M%S")
    end
  end
end
