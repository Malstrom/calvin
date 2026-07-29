# frozen_string_literal: true
# Costruisce il prompt utente per il ReActLoop.
#
# Fonti:
#   1. title + body dell'issue, con header espliciti # Task / ## Description
#   2. NEXT_MIGRATION_VERSION calcolata dal repo target
#
# NEXT_MIGRATION_VERSION va nel prompt perché è un dato che Calvin conosce esattamente:
# far indovinare al modello il timestamp floor gli costava turni di esplorazione
# (list db/migrate + read dell'ultima migration) per arrivare a un valore che qui si
# calcola con certezza. Il Validator verifica poi che il timestamp prodotto sia coerente.
#
# Nota: il retrieval RAG è responsabilità di ExploreFlow (step retrieve_context),
# non di questo builder.

module Calvin
  class ContextBuilder
    MIGRATIONS_PATH = "db/migrate"

    # reader: Calvin::RepoReader | Calvin::GitHubClient | nil
    # github_client: resta accettato come alias, per i call site esistenti.
    def self.build(issue, reader: nil, github_client: nil)
      source = reader || github_client
      title  = issue.title.to_s.strip
      body   = issue.body.to_s.strip

      raise "Issue ##{issue.number}: title e body vuoti." if title.empty? && body.empty?

      Calvin::LOG.info "--- issue ##{issue.number} context ---"
      Calvin::LOG.info "  title : #{title}"
      Calvin::LOG.info "  body  : #{body.empty? ? '(vuoto)' : body[0..120].gsub("\n", " ")}"
      Calvin::LOG.info "  bytes : #{(title + body).bytesize}"

      parts = ["# Task: #{title}"]
      parts << "## Description\n\n#{body}" unless body.empty?
      content = parts.join("\n\n")

      if source
        next_version = next_migration_version(source)
        content = "NEXT_MIGRATION_VERSION: #{next_version}\n\n#{content}"
        Calvin::LOG.info "  migration_version : #{next_version}"
      end

      content
    end

    # Timestamp per una nuova migration: ultimo esistente + 1, o l'ora corrente se il
    # repo non ha ancora migration.
    def self.next_migration_version(source)
      entries = source.list_directory(MIGRATIONS_PATH)
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
