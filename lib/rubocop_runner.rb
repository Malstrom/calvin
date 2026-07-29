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
require "json"
require "shellwords"

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

    # Offese che rubocop NON è in grado di correggere da solo.
    #
    # Distinzione importante: un'offesa correggibile (`correctable: true`) non deve far
    # scattare il repair loop — mandarla al modello significherebbe spendere token per
    # qualcosa che `rubocop --autocorrect` sistema gratis nel post-step. Sono le offese
    # non correggibili (Style/Documentation, Metrics/*, Naming/*, …) quelle che restano
    # rosse nel lint del repo target e che solo il modello può risolvere.
    #
    # → { count: Integer, output: String, paths: [String] } | nil se rubocop non è eseguibile
    def self.remaining_offenses(files:, github: nil)
      rb_files = files.select { |f| f[:path].end_with?(".rb") }
      return nil if rb_files.empty?

      Dir.mktmpdir("calvin-rubocop-check-") do |tmpdir|
        rb_files.each do |f|
          dest = File.join(tmpdir, f[:path])
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, f[:content])
        end

        config_flag = github ? fetch_rubocop_config(tmpdir, github) : ""
        targets     = rb_files.map { |f| Shellwords.escape(File.join(tmpdir, f[:path])) }.join(" ")
        json_path   = File.join(tmpdir, ".rubocop-report.json")

        # --autocorrect prima (le correggibili spariscono), poi il report su file:
        # scrivere il JSON fuori da stdout evita che il banner dei "pending cops"
        # finisca dentro il payload.
        `rubocop #{config_flag} --autocorrect --format quiet #{targets} 2>&1`
        `rubocop #{config_flag} --no-color --format json --out #{Shellwords.escape(json_path)} #{targets} 2>&1`
        return nil unless File.exist?(json_path)

        report   = JSON.parse(File.read(json_path))
        blocking = blocking_offenses(report, tmpdir)

        {
          count:  blocking.size,
          output: format_offenses(blocking),
          paths:  blocking.map { |o| o[:path] }.uniq
        }
      end
    rescue => e
      Calvin::LOG.warn "RubocopRunner.remaining_offenses FAILED: #{e.class} — #{e.message}"
      nil
    end

    # I path della tmpdir non dicono nulla al modello: vanno riportati a path di progetto.
    def self.blocking_offenses(report, tmpdir)
      prefix = "#{tmpdir}/"

      Array(report["files"]).flat_map do |file|
        path = file["path"].to_s.delete_prefix(prefix)

        Array(file["offenses"]).reject { |o| o["correctable"] }.map do |o|
          {
            path:     path,
            line:     o.dig("location", "line"),
            column:   o.dig("location", "column"),
            cop:      o["cop_name"],
            message:  o["message"],
            severity: o["severity"]
          }
        end
      end
    end
    private_class_method :blocking_offenses

    def self.format_offenses(offenses)
      return "nessuna offesa non correggibile" if offenses.empty?

      offenses.map do |o|
        "#{o[:path]}:#{o[:line]}:#{o[:column]}: #{o[:cop]}: #{o[:message]}"
      end.join("\n")
    end
    private_class_method :format_offenses

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
