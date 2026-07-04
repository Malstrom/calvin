# frozen_string_literal: true
# Applica rubocop --autocorrect sui file .rb generati dal modello,
# prima del commit. Corregge style violations in-process via Tempfile.
#
# Uso:
#   include RubocopAutocorrect
#   files = autocorrect_files(files)
#
# I file non .rb vengono restituiti invariati.
# Se rubocop fallisce su un file, logga un warning e restituisce il file originale.
#
# Nota: usa BUNDLE_GEMFILE di calvin (impostato dal workflow) per garantire
# che rubocop sia disponibile anche quando Calvin gira nel target repo.

require "tempfile"

module RubocopAutocorrect
  RUBOCOP_CMD = begin
    gemfile = ENV["BUNDLE_GEMFILE"]
    if gemfile && File.exist?(gemfile)
      "BUNDLE_GEMFILE=#{gemfile} bundle exec rubocop"
    else
      "rubocop"
    end
  end.freeze

  def autocorrect_files(files)
    files.map do |f|
      next f unless f[:path].end_with?(".rb")

      begin
        Tempfile.create(["calvin_rubocop", ".rb"]) do |tmp|
          tmp.write(f[:content])
          tmp.flush

          out = `#{RUBOCOP_CMD} --autocorrect --no-color -f quiet #{tmp.path} 2>&1`
          if $?.success? || $?.exitstatus == 1  # exitstatus 1 = offenses found but corrected
            corrected = File.read(tmp.path)
            Calvin::LOG.info "rubocop autocorrect: #{f[:path]} (#{f[:content].lines.size} → #{corrected.lines.size} lines)"
            { path: f[:path], content: corrected }
          else
            Calvin::LOG.warn "rubocop error su #{f[:path]} (exit #{$?.exitstatus}): #{out[0..200]}"
            f
          end
        end
      rescue => e
        Calvin::LOG.warn "rubocop rescue #{f[:path]}: #{e.message}"
        f
      end
    end
  end
end
