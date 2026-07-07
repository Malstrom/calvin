#!/usr/bin/env ruby
# frozen_string_literal: true
# Entry point CLI per l'ingestion RAG.
#
# Usage:
#   ruby bin/ingest.rb --repo Malstrom/synca
#   ruby bin/ingest.rb --repo Malstrom/synca --only docs
#   ruby bin/ingest.rb --repo Malstrom/synca --only pr

require "optparse"
require "base64"
require_relative "../lib/ingestion/chunker"
require_relative "../lib/ingestion/embedder"
require_relative "../lib/ingestion/supabase_store"
require_relative "../lib/ingestion/pr_fetcher"

# ── Helpers ───────────────────────────────────────────────────────────────────
def collect_md_files(client, repo, entry)
  if entry.type == "dir"
    client.contents(repo, path: entry.path).flat_map { |e| collect_md_files(client, repo, e) }
  elsif entry.name.end_with?(".md")
    [entry.path]
  else
    []
  end
rescue Octokit::NotFound
  []
end

# ── CLI ───────────────────────────────────────────────────────────────────────
options = { only: nil }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/ingest.rb --repo OWNER/REPO [--only docs|pr]"
  opts.on("--repo REPO", "Target repo (e.g. Malstrom/synca)") { |v| options[:repo] = v }
  opts.on("--only TYPE", "Ingest only 'docs' or 'pr'") { |v| options[:only] = v }
end.parse!

raise "--repo is required" unless options[:repo]

repo     = options[:repo]
only     = options[:only]
store    = Ingestion::SupabaseStore.new
embedder = Ingestion::Embedder.new

total_chunks  = 0
total_upserts = 0
errors        = []

# ── DOCS ──────────────────────────────────────────────────────────────────────
unless only == "pr"
  puts "[ingest] Fetching docs from #{repo}..."
  fetcher = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))

  doc_files = []
  ["docs"].each do |dir|
    begin
      fetcher.contents(repo, path: dir).each do |entry|
        doc_files.concat(collect_md_files(fetcher, repo, entry))
      end
    rescue Octokit::NotFound
      puts "[ingest] WARN: #{dir}/ not found in #{repo}, skipping."
    end
  end

  doc_files.each do |file_path|
    begin
      raw = Base64.decode64(fetcher.contents(repo, path: file_path).content)
                  .force_encoding("UTF-8")
      chunks = Ingestion::Chunker.split(raw, source_path_prefix: file_path)
      chunks.each do |chunk|
        embedding = embedder.embed(chunk[:content])
        store.upsert(
          repo:        repo,
          source_type: chunk[:source_type],
          source_path: chunk[:source_path],
          content:     chunk[:content],
          embedding:   embedding
        )
        total_upserts += 1
      end
      total_chunks += chunks.size
      puts "[ingest] #{file_path} → #{chunks.size} chunk(s)"
    rescue => e
      errors << "#{file_path}: #{e.message}"
      puts "[ingest] ERROR #{file_path}: #{e.message}"
    end
  end
end

# ── PR ────────────────────────────────────────────────────────────────────────
unless only == "docs"
  puts "[ingest] Fetching merged PRs from #{repo}..."
  prs = Ingestion::PrFetcher.merged_since(repo, days: 90)
  prs.each do |pr|
    begin
      embedding = embedder.embed(pr[:content])
      store.upsert(
        repo:        repo,
        source_type: "pr",
        source_path: "pr/#{pr[:number]}",
        content:     pr[:content],
        embedding:   embedding
      )
      total_chunks  += 1
      total_upserts += 1
      puts "[ingest] PR ##{pr[:number]} → upserted"
    rescue => e
      errors << "pr/#{pr[:number]}: #{e.message}"
      puts "[ingest] ERROR pr/#{pr[:number]}: #{e.message}"
    end
  end
end

# ── SUMMARY ───────────────────────────────────────────────────────────────────
puts ""
puts "[ingest] ✅ Done. chunks=#{total_chunks} upserts=#{total_upserts} errors=#{errors.size}"
errors.each { |e| puts "  ✗ #{e}" }
exit(errors.any? ? 1 : 0)
