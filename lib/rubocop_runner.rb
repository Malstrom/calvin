# frozen_string_literal: true
# Calvin::RubocopRunner — logica core di rubocop autocorrect.
#
# Responsabilità singola: riceve file in memoria, li autocorregge in tmpdir,
# restituisce i file modificati + esito esplicito.
#
# Differenza rispetto al vecchio RubocopAutocorrect:
#   - Cerca .rubocop.yml nel REPO TARGET (via github.get_file_content),
#     non in Dir.pwd (che punta alla directory di Calvin, non di synca).
#   - Ritorna un hash strutturato invece di side-effect puri.
#   - Non committa — quella responsabilità resta in RubocopAutocorrect / PostSteps.
#
# API:
#   Calvin::RubocopRunner.run(files:, github:)
#   → { corrected: [{ path:, content: }], status: :ok | :noop | :error }
#
#   corrected: file che sono cambiati dopo autocorrect
#   status:
#     :ok    — rubocop eseguito, corrected.size >= 0
#     :noop  — nessun file .rb da correggere
#     :error — rubocop ha sollevato un'eccezione

require "fileutils"
require "tmpdir"

module Calvin
  module RubocopRunner
    RUBOCOP_CONFIG_PATH = ".rubocop.yml"

    def self.run(files:, github:)
      rb_files = files.select { |f| f[:path].end_with?(".rb") }
      return { corrected: [], status: :noop } if rb_files.empty?

      Dir.mktmpdir("calvin-rubocop-") do |tmpdir|
        rb_files.each do |f|
          dest = File.join(tmpdir, f[:path])
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, f[:content])
        end

        config_flag = fetch_rubocop_config(tmpdir, github)
        targets     = rb_files.map { |f| File.join(tmpdir, f[:path]) }.join(" ")
        output      = `rubocop #{config_flag} --autocorrect --format quiet #{targets} 2>&1`
        Calvin::LOG.info "RubocopRunner: #{output.strip.split("\n").last}"

        corrected = rb_files.filter_map do |f|
          new_content = File.read(File.join(tmpdir, f[:path]))
          new_content == f[:content] ? nil : { path: f[:path], content: new_content }
        end

        { corrected: corrected, status: :ok }
      end
    rescue => e
      Calvin::LOG.warn "RubocopRunner FAILED: #{e.class} — #{e.message}"
      { corrected: [], status: :error }
    end

    # Scarica .rubocop.yml dal repo target (non da Dir.pwd di Calvin).
    # Lo scrive nella tmpdir e restituisce il flag --config per rubocop.
    # Se il file non esiste nel repo target, rubocop gira senza config esplicita.
    def self.fetch_rubocop_config(tmpdir, github)
      content = github.get_file_content(RUBOCOP_CONFIG_PATH)
      return "" unless content

      config_path = File.join(tmpdir, RUBOCOP_CONFIG_PATH)
      File.write(config_path, content)
      Calvin::LOG.info "RubocopRunner: usata config #{RUBOCOP_CONFIG_PATH} dal repo target"
      "--config #{config_path}"
    rescue => e
      Calvin::LOG.warn "RubocopRunner: impossibile caricare .rubocop.yml — #{e.message}"
      ""
    end
    private_class_method :fetch_rubocop_config
  end
end
