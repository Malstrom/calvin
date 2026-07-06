# frozen_string_literal: true
# PrReviewFlow — flusso PR-based per fix di test falliti.
#
# Attivato dalla label `calvin-fix` su una PR di synca.
# NON usa ReActLoop: il contesto è già noto (errore CI + file dal backtrace).
# Singola call LLM (temperatura 0.0).
#
# Flusso:
#   1. Legge il commento bot CI con i test falliti dalla PR
#   2. Estrae i file incriminati dal backtrace (BacktraceExtractor)
#      → filtra per perimetro PR + esclude /test/
#   3. Recupera gli snippet ±N righe attorno alla riga del backtrace (dal branch PR)
#   4. Singola call LLM → REVIEW_COMMENT_START/END + FILE: blocks
#   5. Commita i FILE: blocks sul branch della PR
#   6. Posta il commento di review sulla PR (firmato con token usage + checkbox)
#
# Contratto risultato (identico a ExploreFlow):
#   Success(Calvin::FlowResult)
#   Failure({ step:, error:, usage: })

require "dry/monads"
require_relative "file_parser"
require_relative "flow_result"
require_relative "mistral_client"
require_relative "pr_body_builder"

module Calvin
  class PrReviewFlow
    include Dry::Monads[:result]

    PROMPTS_DIR   = File.expand_path("../../config/prompts", __FILE__)
    SYSTEM_PROMPT = File.join(PROMPTS_DIR, "rails", "pr_review_system.md")
    CI_BOT_MARKER = "<!-- ci-report -->"
    REVIEW_START  = "REVIEW_COMMENT_START"
    REVIEW_END    = "REVIEW_COMMENT_END"
    SNIPPET_LINES = (Calvin::CONFIG.dig(:pr_review, :snippet_context_lines) || 20)
    TEMPERATURE   = (Calvin::CONFIG.dig(:sampling, :temperature, :pr_review) || 0.0)

    def self.run(github, pull_request, pr_files)
      new(github, pull_request, pr_files).call
    end

    def initialize(github, pull_request, pr_files)
      @github       = github
      @pull_request = pull_request
      @pr_files     = pr_files
      @mistral      = MistralClient.new
    end

    def call
      # 1. Commento CI bot
      error_comment = fetch_ci_failure_comment
      unless error_comment
        Calvin::LOG.warn "PrReviewFlow: nessun commento CI bot trovato sulla PR ##{pr_number}"
        return Failure(step: :fetch_ci_comment, error: "no CI failure comment found", usage: nil)
      end

      # 2. Estrae file incriminati (perimetro PR, no test/)
      targets = BacktraceExtractor.extract(error_comment, @pr_files)
      if targets.empty?
        Calvin::LOG.warn "PrReviewFlow: nessun file in scope nel backtrace"
        return Failure(step: :backtrace_extract, error: "no fixable files in backtrace within PR scope", usage: nil)
      end

      Calvin::LOG.info "PrReviewFlow: file in scope → #{targets.map { |t| t[:path] }.join(', ')}"

      # 3. Recupera snippet dal branch della PR
      snippets = targets.map { |t| fetch_snippet(t, ref: head_branch) }.compact
      if snippets.empty?
        return Failure(step: :fetch_snippets, error: "could not fetch any file snippet from PR branch", usage: nil)
      end

      # 4. Call LLM
      user_prompt   = build_user_prompt(error_comment, snippets)
      system_prompt = File.read(SYSTEM_PROMPT, encoding: "UTF-8")
      Calvin::LOG.info "PrReviewFlow: call LLM (temp=#{TEMPERATURE})"

      response = @mistral.complete_messages(
        [
          { role: "system", content: system_prompt },
          { role: "user",   content: user_prompt }
        ],
        temperature: TEMPERATURE
      )

      raw   = response[:content]
      usage = response[:usage]
      Calvin::LOG.info "PrReviewFlow: LLM response (#{raw.bytesize} bytes)"

      # 5. Parsa output
      review_text  = extract_review_comment(raw)
      parsed_files = FileParser.parse(raw)

      # 6. Commita se ci sono file da fixare
      if parsed_files.any?
        @github.commit_files_atomically(
          parsed_files,
          message: "fix: Calvin review fix on PR ##{pr_number}",
          branch:  head_branch
        )
        Calvin::LOG.info "PrReviewFlow: #{parsed_files.size} file committati su #{head_branch}"
      else
        Calvin::LOG.info "PrReviewFlow: nessun FILE: block — fix impossibile o non necessario"
      end

      # 7. Posta commento firmato con token usage + checkbox
      comment_body = PrBodyBuilder.review_comment(usage: usage, review_text: review_text)
      @github.post_pr_comment(pr_number, comment_body)
      Calvin::LOG.info "PrReviewFlow: commento review postato su PR ##{pr_number}"

      Success(
        Calvin::FlowResult.success(
          files:     parsed_files.map { |f| f[:path] },
          branch:    head_branch,
          usage:     usage,
          flow_meta: { files_fixed: parsed_files.size }
        )
      )
    rescue => e
      Calvin::LOG.error "PrReviewFlow error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      Failure(step: :pr_review_flow, error: e.message, usage: nil)
    end

    private

    def pr_number
      @pull_request[:number] || @pull_request.number
    end

    def head_branch
      @pull_request[:head_branch] || @pull_request.head.ref
    end

    def fetch_ci_failure_comment
      comments = @github.issue_comments(@pull_request)
      comments
        .select { |c| c.body.include?(CI_BOT_MARKER) }
        .max_by(&:created_at)
        &.body
    end

    module BacktraceExtractor
      BACKTRACE_RE = /^\s+(\S+\.rb):(\d+):/.freeze
      APP_ROOT_RE  = %r{(?:^|/)(?=app/|lib/|config/)}.freeze

      def self.extract(error_text, pr_files)
        pr_set = pr_files.to_set
        error_text
          .scan(BACKTRACE_RE)
          .map    { |path, line| { path: normalize(path), line: line.to_i } }
          .reject { |t| t[:path].include?("/test/") || t[:path].start_with?("test/") }
          .select { |t| pr_set.include?(t[:path]) }
          .uniq   { |t| t[:path] }
      end

      def self.normalize(raw_path)
        if (m = raw_path.match(APP_ROOT_RE))
          raw_path[m.end(0)..]
        else
          raw_path
        end
      end
    end

    def fetch_snippet(target, ref:)
      raw_content = @github.get_file_content(target[:path], ref: ref)
      unless raw_content
        Calvin::LOG.warn "PrReviewFlow: file non trovato su branch #{ref}: #{target[:path]}"
        return nil
      end

      # Base64.decode64 ritorna ASCII-8BIT — forza UTF-8 per evitare
      # incompatible encoding errors nel join del prompt
      content = raw_content.force_encoding("UTF-8")

      lines      = content.lines
      center     = target[:line] - 1
      from       = [center - SNIPPET_LINES, 0].max
      to         = [center + SNIPPET_LINES, lines.size - 1].min
      snippet    = lines[from..to].join
      start_line = from + 1

      { path: target[:path], snippet: snippet, line: target[:line], start_line: start_line }
    end

    def build_user_prompt(error_comment, snippets)
      parts = []
      parts << "## Failing test output"
      parts << error_comment.strip
      parts << "## Files in scope"
      snippets.each do |s|
        parts << "FILE SNIPPET: #{s[:path]} (lines #{s[:start_line]}-#{s[:start_line] + s[:snippet].lines.size - 1})"
        parts << "```ruby"
        parts << s[:snippet].chomp
        parts << "```"
        parts << ""
      end
      parts.join("\n")
    end

    def extract_review_comment(raw)
      match = raw.match(/#{REVIEW_START}\s*\n(.*?)\n#{REVIEW_END}/m)
      match&.captures&.first&.strip
    end
  end
end
