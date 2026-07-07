# frozen_string_literal: true
# PrFetcher — recupera PR merged recenti da GitHub API.
#
# Ingestion::PrFetcher.merged_since("Malstrom/synca", days: 90)
# → [{ number: Int, content: String }, ...]
#
# content = "PR #N: <titolo>\n\n<body>\n\nFiles: file1, file2, ..."
# Usa Octokit (già dipendenza di Calvin) con GITHUB_TOKEN.

require "octokit"
require "base64"

module Ingestion
  class PrFetcher
    def self.merged_since(repo, days: 90)
      client    = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
      since     = Time.now - (days * 86_400)
      page      = 1
      results   = []

      loop do
        prs = client.pull_requests(repo, state: "closed", sort: "updated", direction: "desc", per_page: 50, page: page)
        break if prs.empty?

        prs.each do |pr|
          next unless pr.merged_at
          break if pr.merged_at < since

          files   = client.pull_request_files(repo, pr.number).map(&:filename).join(", ")
          body    = pr.body.to_s.strip
          content = "PR ##{pr.number}: #{pr.title}\n\n#{body}\n\nFiles: #{files}".strip

          results << { number: pr.number, content: content }
        end

        # Se l'ultima PR della pagina è già fuori finestra, stop
        break if prs.last&.merged_at && prs.last.merged_at < since
        break if prs.size < 50

        page += 1
      end

      results
    end
  end
end
