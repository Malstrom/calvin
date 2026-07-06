# frozen_string_literal: true
# Costruisce il prompt per il ReActLoop.
#
# Unica fonte: title + body dell'issue.
# Inietta NEXT_MIGRATION_VERSION leggendo l'ultima migrazione
# dal repo target — il modello non deve mai inventarsi un timestamp.

module Calvin
  class ContextBuilder
    MIGRATIONS_PATH = "db/migrate"

    def self.build(issue, github_client: nil)
      title   = issue.title.to_s.strip
      body    = issue.body.to_s.strip
      content = [title, body].reject(&:empty?).join("\n\n")

      raise "Issue ##{issue.number}: title e body vuoti." if content.empty?

      Calvin::LOG.info "context_builder: issue ##{issue.number} (#{content.bytesize} bytes)"
      Calvin::LOG.info "context_builder: prompt[:20] = #{content[0..19].inspect}"

      if github_client
        next_version = next_migration_version(github_client)
        content = "NEXT_MIGRATION_VERSION: #{next_version}\n\n#{content}"
        Calvin::LOG.info "context_builder: NEXT_MIGRATION_VERSION=#{next_version}"
      end

      content
    end

    # Legge la directory db/migrate, ordina i nomi, prende il timestamp
    # dell'ultimo file e restituisce timestamp+1 (come stringa a 14 cifre).
    # Fallback: usa Time.now.utc formattato.
    def self.next_migration_version(github_client)
      entries = github_client.list_directory(MIGRATIONS_PATH)
      # I file di migrazione hanno formato: 20240715120000_nome.rb
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
