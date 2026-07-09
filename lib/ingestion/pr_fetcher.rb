# frozen_string_literal: true
# PrFetcher — recupera PR merged da GitHub API.
#
# Ingestion::PrFetcher.merged_since("Malstrom/synca", days: 90)
# → [{ number: Int, content: String }, ...]
#
# Ingestion::PrFetcher.single("Malstrom/synca", 42)
# → { number: 42, content: String } | nil
#
# content = "PR #N: <titolo>\n\n<body>\n\nFiles: file1, file2, ..."

require "octokit"
require "base64"

module Ingestion
  class PrFetcher
    def self.client
      Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
    end

    def self.build_content(pr, files)
      body    = pr.body.to_s.strip
      "PR ##{pr.number}: #{pr.title}\n\n#{body}\n\nFiles: #{files}".strip
    end

    # Fetch a single PR by number. Returns nil if not found or not merged.
    def self.single(repo, pr_number)
      c  = client
      pr = c.pull_request(repo, pr_number)
      return nil unless pr.merged_at

      files   = c.pull_request_files(repo, pr_number).map(&:filename).join(", ")
      content = build_content(pr, files)
      { number: pr.number, content: content }
    rescue Octokit::NotFound
      nil
    end

    # Fetch all PRs merged in the last N days.
    def self.merged_since(repo, days: 90)
      c       = client
      since   = Time.now - (days * 86_400)
      page    = 1
      results = []

      loop do
        prs = c.pull_requests(repo, state: "closed", sort: "updated", direction: "desc", per_page: 50, page: page)
        break if prs.empty?

        prs.each do |pr|
          next unless pr.merged_at
          break if pr.merged_at < since

          files   = c.pull_request_files(repo, pr.number).map(&:filename).join(", ")
          content = build_content(pr, files)
          results << { number: pr.number, content: content }
        end

        break if prs.last&.merged_at && prs.last.merged_at < since
        break if prs.size < 50

        page += 1
      end

      results
    end
  end
end
