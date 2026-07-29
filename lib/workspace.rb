# frozen_string_literal: true
# Calvin::Workspace — accesso al clone locale del repo target.
#
# Il workflow fa già `actions/checkout` del repo target in `target/`, ma prima di questa
# classe nessuno lo usava: ogni lettura passava dalla Contents API di GitHub, un file alla
# volta (centinaia di ms per file, rate limit, e `grep` su directory che riscaricava ogni file).
#
# Responsabilità singola: I/O su filesystem dentro la root del repo target.
# La scrittura su GitHub (branch, commit, PR) resta in GitHubClient — questa classe non
# tocca la rete.
#
# Tutti i path sono relativi alla root dell'applicazione (es. "app/models/user.rb"),
# esattamente come i path che il modello produce: il prefisso repo_root (es. "backend/api")
# viene applicato internamente, come fa GitHubClient#full_path.
#
# Uso:
#   ws = Calvin::Workspace.new(repo_root: "backend/api")
#   ws.available?              # => true se la root esiste su disco
#   ws.read("app/models/user.rb")   # => String | nil
#   ws.list("app/models")           # => ["user.rb", ...]
#   ws.grep("auth", "config/routes.rb")
#   ws.write("app/services/foo.rb", content)
#
# Sicurezza: ogni path viene risolto e verificato dentro la root — un path con ".." o
# assoluto solleva un errore invece di leggere o scrivere fuori dal repo target.

require "open3"
require "fileutils"

module Calvin
  class Workspace
    class PathEscape < StandardError; end

    DEFAULT_TARGET_PATH = "../target"

    def initialize(repo_root: "", target_path: nil)
      @repo_root = repo_root.to_s
      base       = target_path ||
                   ENV["CALVIN_TARGET_PATH"] ||
                   Calvin::CONFIG.dig(:workspace, :target_path) ||
                   DEFAULT_TARGET_PATH
      @base = File.expand_path(base)
      @root = @repo_root.empty? ? @base : File.join(@base, @repo_root)
    end

    attr_reader :root, :base

    # true se il clone è presente su disco. Se false, i chiamanti ricadono su GitHubClient.
    def available?
      Dir.exist?(@root)
    end

    def exist?(path)
      File.exist?(absolute(path))
    end

    # Contenuto del file, o nil se non esiste (stessa semantica di GitHubClient#get_file_content).
    def read(path)
      full = absolute(path)
      return nil unless File.file?(full)

      File.read(full, encoding: "UTF-8")
    end

    # Nomi delle entry immediate di una directory. [] se non esiste.
    def list(path)
      full = path.to_s.empty? ? @root : absolute(path)
      return [] unless Dir.exist?(full)

      Dir.children(full).sort
    end

    # Cerca pattern (case-insensitive, letterale) in un file o in una directory.
    # Formato di ritorno identico a GitHubClient#grep_files: "path:line: contenuto",
    # così il ReActLoop non distingue la sorgente.
    def grep(pattern, path)
      full = path.to_s.empty? ? @root : absolute(path)
      return "ERROR: file or directory not found: #{path}" unless File.exist?(full)

      out, _err, _status = Open3.capture3(
        "rg", "--fixed-strings", "--ignore-case", "--line-number", "--no-heading",
        "--max-count", max_results.to_s, "--", pattern.to_s, full
      )

      lines = out.to_s.lines.map { |l| relativize(l.chomp) }.reject(&:empty?)
      return "ERROR: no matches for '#{pattern}' in #{path}" if lines.empty?

      lines.first(max_results).join("\n")
    rescue Errno::ENOENT
      # rg non installato — fallback puro Ruby, stesso formato di output
      grep_fallback(pattern, path)
    end

    # Scrive un file creando le directory intermedie. Usato dal Validator per materializzare
    # i file generati prima di eseguire i gate.
    def write(path, content)
      full = absolute(path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      full
    end

    # Timestamp più alto presente in db/migrate, o nil se non ci sono migration.
    # Sostituisce la lettura via API in ContextBuilder quando il clone è disponibile.
    def latest_migration_version
      list("db/migrate")
        .filter_map { |f| f[/\A(\d{14})_/, 1] }
        .max
    end

    private

    def max_results
      Calvin::CONFIG.dig(:workspace, :grep_max_results) || 80
    end

    # Risolve il path dentro la root e verifica che non ne esca.
    def absolute(path)
      cleaned = path.to_s.strip.delete_prefix("./")
      raise PathEscape, "absolute path not allowed: #{path}" if cleaned.start_with?("/")

      full = File.expand_path(File.join(@root, cleaned))
      unless full == @root || full.start_with?("#{@root}/")
        raise PathEscape, "path escapes the target repo: #{path}"
      end

      full
    end

    # Riporta i path assoluti di rg a path relativi alla root dell'applicazione.
    def relativize(line)
      prefix = "#{@root}/"
      line.start_with?(prefix) ? line.delete_prefix(prefix) : line
    end

    def grep_fallback(pattern, path)
      full   = path.to_s.empty? ? @root : absolute(path)
      regex  = Regexp.new(Regexp.escape(pattern.to_s), Regexp::IGNORECASE)
      files  = File.directory?(full) ? Dir.glob(File.join(full, "*")).select { |f| File.file?(f) } : [full]

      results = files.flat_map do |file|
        File.foreach(file).with_index(1).filter_map do |line, idx|
          next unless line.match?(regex)

          relativize("#{file}:#{idx}: #{line.chomp}")
        end
      rescue ArgumentError
        [] # file binario
      end

      results.empty? ? "ERROR: no matches for '#{pattern}' in #{path}" : results.first(max_results).join("\n")
    end
  end
end
