# frozen_string_literal: true
# Esegue rubocop --autocorrect sui file .rb di un commit
# e se ci sono correzioni le committa come secondo commit separato.
#
# Non bloccante: qualsiasi errore viene loggato e ignorato.
# Con squash merge i due commit collassano in uno su main.
#
# Uso:
#   Calvin::RubocopAutocorrect.run(files:, branch:, github:)

require "fileutils"
require "tmpdir"

module Calvin
  module RubocopAutocorrect
    def self.run(files:, branch:, github:)
      rb_files = files.select { |f| f[:path].end_with?(".rb") }
      if rb_files.empty?
        Calvin::LOG.info "RubocopAutocorrect: nessun file .rb — skip"
        return
      end

      Dir.mktmpdir("calvin-rubocop-") do |tmpdir|
        # Scrivi i file nella tmpdir rispettando la struttura delle cartelle
        rb_files.each do |f|
          dest = File.join(tmpdir, f[:path])
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, f[:content])
        end

        rubocop_config = find_rubocop_config
        config_flag    = rubocop_config ? "--config #{rubocop_config}" : ""
        targets        = rb_files.map { |f| File.join(tmpdir, f[:path]) }.join(" ")

        output = `rubocop #{config_flag} --autocorrect --format quiet #{targets} 2>&1`
        Calvin::LOG.info "RubocopAutocorrect: #{output.strip.split("\n").last}"

        corrected = rb_files.filter_map do |f|
          new_content = File.read(File.join(tmpdir, f[:path]))
          new_content == f[:content] ? nil : { path: f[:path], content: new_content }
        end

        if corrected.empty?
          Calvin::LOG.info "RubocopAutocorrect: nessuna correzione necessaria"
          return
        end

        Calvin::LOG.info "RubocopAutocorrect: #{corrected.size} file(s) corretti — secondo commit"
        github.commit_files_atomically(
          corrected,
          message: "chore: rubocop autocorrect",
          branch:  branch
        )
      end
    rescue => e
      Calvin::LOG.warn "RubocopAutocorrect FAILED (non bloccante): #{e.class} — #{e.message}"
    end

    def self.find_rubocop_config
      candidate = File.join(Dir.pwd, ".rubocop.yml")
      File.exist?(candidate) ? candidate : nil
    end
    private_class_method :find_rubocop_config
  end
end
