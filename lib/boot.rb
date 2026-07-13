# frozen_string_literal: true
# Bootstrap Calvin — caricato come primo require da bin/calvin.rb.
# Imposta costanti globali, logger, e dipendenze.

require "yaml"
require "logger"
require "csv"
require "octokit"
require "dry/monads"
require "dry/transaction"

module Calvin
  # Colori ANSI — usati solo se stdout è un TTY (es. run locale).
  # In CI / GitHub Actions stdout viene rediretto a file — i colori vengono
  # automaticamente disabilitati per evitare escape sequences nei log.
  module Color
    TTY = $stdout.isatty

    RESET  = TTY ? "\e[0m"  : ""
    BOLD   = TTY ? "\e[1m"  : ""
    DIM    = TTY ? "\e[2m"  : ""
    CYAN   = TTY ? "\e[36m" : ""
    YELLOW = TTY ? "\e[33m" : ""
    RED    = TTY ? "\e[31m" : ""
    GREEN  = TTY ? "\e[32m" : ""
    GRAY   = TTY ? "\e[90m" : ""
    BLUE   = TTY ? "\e[34m" : ""

    def self.reset  = RESET
    def self.bold   = BOLD
    def self.dim    = DIM
    def self.cyan   = CYAN
    def self.yellow = YELLOW
    def self.red    = RED
    def self.green  = GREEN
    def self.gray   = GRAY
    def self.blue   = BLUE
  end

  # Logger con formatter leggibile.
  #
  # Formato base:
  #   13:16:01  INFO   ExploreFlow  prompt built (1.2 KB)
  #   13:16:02  WARN   ReActLoop    JSON parse failed (1/2)
  #
  # Helper globali per separatori e banner (chiamati direttamente dal codice):
  #   Calvin::LOG.banner("EXPLORE")    → riga "=" con titolo centrato
  #   Calvin::LOG.section("turn 3")    → riga "-" con titolo
  #   Calvin::LOG.file_read(path, kb)  → riga compatta per file letti
  #   Calvin::LOG.done(msg)            → riga evidenziata per completamento fase
  LOG = Logger.new($stdout).tap do |l|
    l.progname = "calvin"
    l.formatter = proc do |severity, time, _progname, msg|
      ts = time.strftime("%H:%M:%S")

      color = case severity
              when "WARN"  then Color::YELLOW
              when "ERROR" then Color::RED
              when "INFO"  then Color::GRAY
              else Color::RESET
              end

      level = severity.ljust(5)
      "#{Color::DIM}#{ts}#{Color::RESET}  #{color}#{level}#{Color::RESET}  #{msg}\n"
    end
  end

  # Banner visivo per separare le fasi principali del flow.
  # Es: Calvin.banner("EXPLORE")
  #   ╭──────────────────────────────────────────────────────────────╮
  #   │  ✧ EXPLORE                                              │
  #   ╰──────────────────────────────────────────────────────────────╯
  def self.banner(title, emoji: "✧")
    width = 62
    line  = "─" * width
    label = "#{emoji} #{title}"
    pad   = " " * [(width - label.length - 2) / 2, 0].max
    $stdout.puts "#{Color::CYAN}\n╭#{line}\u256e\n│#{pad}  #{Color::BOLD}#{label}#{Color::RESET}#{Color::CYAN}#{' ' * [width - pad.length - label.length - 2, 0].max}  │\n╰#{line}╯#{Color::RESET}"
  end

  # Separatore leggero tra sotto-sezioni.
  # Es: Calvin.section("turn 3 / 30")
  #   ── turn 3 / 30 ──────────────────────────────────────────────
  def self.section(title)
    rest  = ["-" * (50 - title.length - 4), ""].max_by(&:length)
    $stdout.puts "#{Color::BLUE}── #{title} #{rest}#{Color::RESET}"
  end

  # Log compatto per file letti durante l'esplorazione.
  # Evita di stampare le prime N righe del contenuto nel mezzo dei log.
  def self.file_read(path, bytes)
    kb = (bytes / 1024.0).round(1)
    LOG.info "#{Color::GREEN}└ read#{Color::RESET}  #{path}  #{Color::DIM}(#{kb} KB)#{Color::RESET}"
  end

  # Log di completamento fase — evidenziato in verde.
  def self.done(msg)
    LOG.info "#{Color::GREEN}✔ #{msg}#{Color::RESET}"
  end

  # Log di un tool call durante explore (thought + tool + args su 2 righe compatte).
  def self.tool_call(turn, tool, args, thought: nil)
    arg_str = args.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
    thought_line = thought ? "  #{Color::DIM}└ #{thought[0..120]}#{Color::RESET}\n" : ""
    $stdout.puts "#{Color::CYAN}  ▶ turn #{turn}#{Color::RESET}  #{Color::BOLD}#{tool}#{Color::RESET}(#{arg_str})#{thought_line}"
  end

  # Config centralizzata — unica fonte di verità per tutti i parametri.
  # DEVE essere definita prima di qualsiasi require_relative che usa Calvin::CONFIG.
  CONFIG = YAML.load_file(
    File.expand_path("../../config/calvin.yml", __FILE__), symbolize_names: true
  ).freeze

  # Modello attivo — da env o config.
  MODEL = ENV.fetch("CALVIN_MODEL", CONFIG.dig(:model, :default) || "codestral-latest").freeze

  # Repo target — formato "owner/repo".
  # CALVIN_TARGET_REPO è impostato esplicitamente nel workflow Calvin.
  # Fallback a GITHUB_REPOSITORY per compatibilità (es. run locali).
  REPO = ENV.fetch("CALVIN_TARGET_REPO") { ENV.fetch("GITHUB_REPOSITORY") }.freeze

  # Roots per repo target (stack => path relativo).
  REPO_ROOTS = (CONFIG.dig(:repo, :roots) || {}).transform_keys(&:to_s).freeze
end

# Tutti i require_relative vengono DOPO la definizione di Calvin::CONFIG e Calvin::REPO
# perché alcuni moduli accedono a queste costanti a load-time.
#
# Ordine: primitivi → client → parser → flow components → flow → post-steps
require_relative "flow_result"
require_relative "mode_router"
require_relative "github_client"
require_relative "mistral_client"
require_relative "context_retriever"
require_relative "context_builder"
require_relative "file_parser"
require_relative "pr_body_builder"
require_relative "react_loop"
require_relative "commit_and_pr"
require_relative "explore_flow"
require_relative "test_writer"
require_relative "test_flow"
require_relative "rubocop_runner"
require_relative "rubocop_autocorrect"
require_relative "run_reporter"
require_relative "post_steps"
