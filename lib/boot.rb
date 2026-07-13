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
    MAGENTA = TTY ? "\e[35m" : ""

    def self.reset   = RESET
    def self.bold    = BOLD
    def self.dim     = DIM
    def self.cyan    = CYAN
    def self.yellow  = YELLOW
    def self.red     = RED
    def self.green   = GREEN
    def self.gray    = GRAY
    def self.blue    = BLUE
    def self.magenta = MAGENTA
  end

  # Logger con formatter leggibile.
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

  # ─────────────────────────────────────────────────────────────────────────────
  # Visual helpers
  # ─────────────────────────────────────────────────────────────────────────────

  WIDTH = 66

  # Banner principale — usato all'inizio del flow completo.
  #
  #   ╭──────────────────────────────────────────────────────────────────╮
  #   │  🚀 EXPLORE FLOW  •  issue #42                                   │
  #   ╰──────────────────────────────────────────────────────────────────╯
  def self.banner(title, emoji: "✧")
    line  = "─" * WIDTH
    label = "#{emoji}  #{title}"
    pad_r = [WIDTH - label.length - 2, 0].max
    $stdout.puts \
      "#{Color::CYAN}\n" \
      "╭#{line}╮\n" \
      "│  #{Color::BOLD}#{label}#{Color::RESET}#{Color::CYAN}#{' ' * pad_r}│\n" \
      "╰#{line}╯#{Color::RESET}\n"
  end

  # Inizio fase — box con doppia riga, colore per fase.
  #
  #   ╔══════════════════════════════════════════════════════════════════╗
  #   ║  🔍 EXPLORE  ·  turn 1..30  ·  temp=0.1                         ║
  #   ╚══════════════════════════════════════════════════════════════════╝
  PHASE_COLORS = {
    explore:   Color::CYAN,
    implement: Color::MAGENTA,
    commit:    Color::GREEN
  }.freeze

  def self.phase_start(phase, subtitle = nil)
    color = PHASE_COLORS[phase] || Color::CYAN
    line  = "═" * WIDTH
    label = phase.to_s.upcase
    label += "  ·  #{subtitle}" if subtitle
    pad_r = [WIDTH - label.length - 2, 0].max
    $stdout.puts \
      "#{color}\n" \
      "╔#{line}╗\n" \
      "║  #{Color::BOLD}#{label}#{Color::RESET}#{color}#{' ' * pad_r}║\n" \
      "╚#{line}╝#{Color::RESET}\n"
  end

  # Fine fase — riga singola con durata opzionale.
  #
  #   ╸ EXPLORE done  turns=8  00:42  ──────────────────────────────────
  def self.phase_end(phase, details = nil)
    color = PHASE_COLORS[phase] || Color::GREEN
    label = "#{phase.to_s.upcase} done"
    label += "  #{details}" if details
    rest  = "─" * [WIDTH - label.length - 3, 4].max
    $stdout.puts "#{color}╸ #{Color::BOLD}#{label}#{Color::RESET}#{color}  #{rest}#{Color::RESET}\n"
  end

  # Separatore leggero tra sotto-sezioni.
  #
  #   ── rag retrieve ─────────────────────────────────────────────────
  def self.section(title)
    rest = "─" * [WIDTH - title.length - 5, 4].max
    $stdout.puts "#{Color::BLUE}── #{title} #{rest}#{Color::RESET}"
  end

  # Log compatto per file letti durante l'esplorazione.
  def self.file_read(path, bytes)
    kb = (bytes / 1024.0).round(1)
    LOG.info "#{Color::GREEN}└ read#{Color::RESET}  #{path}  #{Color::DIM}(#{kb} KB)#{Color::RESET}"
  end

  # Riepilogo lista file letti a fine fase explore.
  #
  #   ┌─ Files read (8) ─────────────────────────────────────────────┐
  #   │  app/models/user.rb                              1.2 KB       │
  #   │  app/services/magic_link_service.rb              3.4 KB       │
  #   └──────────────────────────────────────────────────────────────┘
  def self.files_read_summary(observations)
    file_obs = observations.reject { |o| o[:label].start_with?("ls ", "grep ") }
    return if file_obs.empty?

    inner = WIDTH - 2
    title = " Files read (#{file_obs.size}) "
    top   = "┌─#{title}#{"─" * [inner - title.length - 1, 2].max}┐"
    bot   = "└#{'─' * inner}┘"

    $stdout.puts "#{Color::GRAY}#{top}"
    file_obs.each do |o|
      kb_str = o[:kb] ? "#{o[:kb]} KB" : ""
      label  = o[:label].length > 52 ? "…#{o[:label][-51..]}" : o[:label]
      row    = "  #{label}"
      pad    = [inner - row.length - kb_str.length, 1].max
      $stdout.puts "│#{row}#{' ' * pad}#{kb_str} │"
    end
    $stdout.puts "#{bot}#{Color::RESET}"
  end

  # Log di completamento generico — evidenziato in verde.
  def self.done(msg)
    LOG.info "#{Color::GREEN}✔ #{msg}#{Color::RESET}"
  end

  # Riepilogo tabellare a fine flow.
  #
  #   ┌─ Flow summary ───────────────────────────────────────────────┐
  #   │  explore turns    8                                           │
  #   │  tokens explore   in=1204 cached=800 out=312                  │
  #   │  tokens impl      in=8420 out=1103                            │
  #   │  files written    3                                           │
  #   │  PR               https://github.com/...                      │
  #   └──────────────────────────────────────────────────────────────┘
  def self.flow_summary(rows)
    inner  = WIDTH - 2
    title  = " Flow summary "
    top    = "┌─#{title}#{"─" * [inner - title.length - 1, 2].max}┐"
    bot    = "└#{'─' * inner}┘"

    $stdout.puts "\n#{Color::GREEN}#{top}"
    rows.each do |key, val|
      val_s = val.to_s
      key_s = "  #{key.to_s.ljust(18)}"
      pad   = [inner - key_s.length - val_s.length, 1].max
      # truncate long values (URLs) gracefully
      if val_s.length > inner - key_s.length - 1
        val_s = "#{val_s[0...(inner - key_s.length - 4)]}…"
        pad   = 1
      end
      $stdout.puts "│#{key_s}#{' ' * pad}#{val_s} │"
    end
    $stdout.puts "#{bot}#{Color::RESET}\n"
  end

  # Log di un tool call durante explore.
  def self.tool_call(turn, tool, args, thought: nil)
    arg_str = args.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
    thought_line = thought ? "\n  #{Color::DIM}  └ #{thought[0..120]}#{Color::RESET}" : ""
    $stdout.puts "#{Color::CYAN}  ▶ turn #{turn}#{Color::RESET}  #{Color::BOLD}#{tool}#{Color::RESET}(#{arg_str})#{thought_line}"
  end

  # Config centralizzata.
  CONFIG = YAML.load_file(
    File.expand_path("../../config/calvin.yml", __FILE__), symbolize_names: true
  ).freeze

  MODEL = ENV.fetch("CALVIN_MODEL", CONFIG.dig(:model, :default) || "codestral-latest").freeze

  REPO = ENV.fetch("CALVIN_TARGET_REPO") { ENV.fetch("GITHUB_REPOSITORY") }.freeze

  REPO_ROOTS = (CONFIG.dig(:repo, :roots) || {}).transform_keys(&:to_s).freeze
end

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
