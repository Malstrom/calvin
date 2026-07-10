# frozen_string_literal: true
# RulesFetcher — estrae le regole checkate dai commenti <!-- calvin:rules --> di una PR.
#
# Ingestion::RulesFetcher.from_pr("Malstrom/synca", 42)
# => [
#   { source_type: "rule", source_path: "rule/42/0_0", content: "..." },
#   { source_type: "rule", source_path: "rule/42/1_0", content: "..." },
# ]
#
# Ritorna [] se:
#   - nessun commento contiene <!-- calvin:rules -->
#   - i commenti esistono ma non hanno bullet checkati (- [x])
#
# Parsing bullet:
#   - Supporta bullet su riga singola:  - [x] Testo. Example: `code`
#   - Supporta bullet multiriga: testo + blocco ```ruby ... ``` indentato
#   - Ignora bullet non checkati: - [ ] ...

require "octokit"

module Ingestion
  class RulesFetcher
    RULES_MARKER     = "<!-- calvin:rules -->"
    CHECKED_BULLET   = /^- \[x\] /i
    UNCHECKED_BULLET = /^- \[ \] /i

    def self.from_pr(repo, pr_number)
      new(repo, pr_number).fetch
    end

    def initialize(repo, pr_number)
      @repo      = repo
      @pr_number = pr_number
      @client    = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
    end

    def fetch
      comments = find_rules_comments
      if comments.empty?
        Calvin::LOG.info "RulesFetcher: no <!-- calvin:rules --> comment found on PR ##{@pr_number}"
        return []
      end

      Calvin::LOG.info "RulesFetcher: #{comments.size} calvin:rules comment(s) found on PR ##{@pr_number}"

      chunks = comments.flat_map.with_index do |comment, ci|
        Calvin::LOG.info "RulesFetcher: processing comment id=#{comment.id} (#{ci + 1}/#{comments.size})"
        extract_checked_bullets(comment.body, comment_index: ci)
      end

      if chunks.empty?
        Calvin::LOG.info "RulesFetcher: comments found but no checked bullets (- [x]) — nothing to ingest"
        return []
      end

      Calvin::LOG.info "RulesFetcher: #{chunks.size} checked bullet(s) extracted"
      chunks
    end

    private

    def find_rules_comments
      found = []
      page  = 1
      loop do
        comments = @client.issue_comments(@repo, @pr_number, per_page: 50, page: page)
        break if comments.empty?

        found.concat(comments.select { |c| c.body.include?(RULES_MARKER) })

        break if comments.size < 50
        page += 1
      end
      found
    rescue Octokit::NotFound
      []
    end

    def extract_checked_bullets(body, comment_index: 0)
      bullets = []
      current = nil

      body.each_line do |line|
        stripped = line.rstrip
        if CHECKED_BULLET.match?(stripped)
          bullets << current if current
          current = { checked: true, lines: [stripped.sub(CHECKED_BULLET, "").strip] }
        elsif UNCHECKED_BULLET.match?(stripped)
          bullets << current if current
          current = { checked: false, lines: [] }
        elsif current
          current[:lines] << stripped unless stripped.empty? && current[:lines].empty?
        end
      end
      bullets << current if current

      bullets
        .select { |b| b[:checked] && b[:lines].any? }
        .each_with_index
        .map do |bullet, i|
          content = bullet[:lines].join("\n").strip
          {
            source_type: "rule",
            source_path: "rule/#{@pr_number}/#{comment_index}_#{i}",
            content:     content
          }
        end
    end
  end
end
