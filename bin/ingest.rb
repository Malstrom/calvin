#!/usr/bin/env ruby
# frozen_string_literal: true
# Entry point CLI per l'ingestion RAG.
#
# Usage:
#   ruby bin/ingest.rb --repo Malstrom/synca --pr 42
#
# Flusso:
#   1. RulesFetcher legge i commenti della PR, trova <!-- calvin:rules -->
#   2. Estrae solo i bullet checkati (- [x])
#   3. Per ogni bullet: embedding -> dedup check -> replace o upsert
#      Se similarity >= DEDUP_THRESHOLD: elimina il vecchio, inserisce il nuovo (replace)
#      Se nessun simile: inserisce direttamente (upsert)
#   4. Dopo tutti i chunk: se ci sono stati replace, posta un commento riepilogativo
#      sulla PR con vecchia regola vs nuova regola + similarity score
#
# Rate limiting: gestito direttamente da Embedder (exponential backoff su 429).

require "optparse"
require_relative "../lib/boot"
require_relative "../lib/ingestion/rules_fetcher"
require_relative "../lib/ingestion/embedder"
require_relative "../lib/ingestion/supabase_store"

DEDUP_THRESHOLD = Calvin::CONFIG.dig(:rag, :dedup_threshold) ||
                  Calvin::CONFIG.dig(:rag, "dedup_threshold") ||
                  0.92

# ── CLI ──────────────────────────────────────────────────────────────────────────
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/ingest.rb --repo OWNER/REPO --pr NUMBER"
  opts.on("--repo REPO",  "Target repo (e.g. Malstrom/synca)") { |v| options[:repo]      = v }
  opts.on("--pr NUMBER",  "PR number to ingest rules from")     { |v| options[:pr_number] = v.to_i }
end.parse!

raise "--repo is required" unless options[:repo]
raise "--pr is required"   unless options[:pr_number]

repo      = options[:repo]
pr_number = options[:pr_number]
store     = Ingestion::SupabaseStore.new
embedder  = Ingestion::Embedder.new

total_upserted  = 0
total_replaced  = 0
errors          = []
replacements    = [] # { old_content:, old_source_path:, new_content:, similarity: }

# ── FETCH RULES ──────────────────────────────────────────────────────────────────────────
puts "[ingest] Fetching rules from PR ##{pr_number} in #{repo}..."

chunks = Ingestion::RulesFetcher.from_pr(repo, pr_number)

if chunks.empty?
  puts "[ingest] WARN: no checked rules found in PR ##{pr_number} — nothing to ingest"
  exit 0
end

puts "[ingest] #{chunks.size} rule(s) to process"
puts ""

# ── PROCESS EACH CHUNK ───────────────────────────────────────────────────────────────────────
chunks.each do |chunk|
  puts "[ingest] ── #{chunk[:source_path]} ─" * 2
  chunk[:content].each_line { |l| puts "[ingest] #{l.rstrip}" }
  puts ""

  begin
    embedding = embedder.embed(chunk[:content])

    # — dedup check ──────────────────────────────────────────────────────────────────────────────
    similar = store.similar_to(embedding, repo: repo, threshold: DEDUP_THRESHOLD, limit: 1)

    if similar.any?
      existing = similar.first
      sim      = existing["similarity"].to_f

      puts "[ingest] → REPLACE (similar chunk found, similarity=#{format('%.4f', sim)})"
      puts "[ingest]   replacing: #{existing['source_path']}"
      puts "[ingest]   old: #{existing['content'].to_s.lines.first.to_s.rstrip}"

      # Elimina il vecchio chunk e inserisce il nuovo
      store.delete_by_source_path(repo: repo, source_path: existing["source_path"])

      replacements << {
        old_content:     existing["content"].to_s.strip,
        old_source_path: existing["source_path"],
        new_content:     chunk[:content].to_s.strip,
        similarity:      sim
      }

      total_replaced += 1
    end

    # — upsert (nuovo o sostitutivo) ───────────────────────────────────────────────────────────────
    store.upsert(
      repo:        repo,
      source_type: chunk[:source_type],
      source_path: chunk[:source_path],
      content:     chunk[:content],
      embedding:   embedding
    )
    puts "[ingest] → upserted"
    total_upserted += 1

  rescue => e
    puts "[ingest] → ERROR: #{e.message}"
    errors << "#{chunk[:source_path]}: #{e.message}"
  end

  puts ""
end

# ── POST REPLACEMENT COMMENT ────────────────────────────────────────────────────────────
if replacements.any?
  github_token = ENV.fetch("GITHUB_TOKEN")
  owner, repo_name = repo.split("/")

  rows = replacements.map.with_index(1) do |r, i|
    <<~ROW
      ### Replacement #{i} — similarity #{format('%.4f', r[:similarity])}

      **Replaced** (`#{r[:old_source_path]}`):
      > #{r[:old_content].gsub("\n", "\n> ")}

      **New rule**:
      > #{r[:new_content].gsub("\n", "\n> ")}
    ROW
  end.join("\n")

  body = <<~COMMENT
    ## ♻️ Calvin ingest — #{replacements.size} rule(s) replaced

    #{rows}
    ---
    _Old rules were removed from the vector DB and replaced with the new versions above._
  COMMENT

  uri = URI("https://api.github.com/repos/#{owner}/#{repo_name}/issues/#{pr_number}/comments")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = Net::HTTP::Post.new(uri)
  req["Authorization"]   = "Bearer #{github_token}"
  req["Content-Type"]    = "application/json"
  req["Accept"]          = "application/vnd.github+json"
  req["X-GitHub-Api-Version"] = "2022-11-28"
  req.body = { body: body }.to_json

  resp = http.request(req)
  if resp.is_a?(Net::HTTPSuccess)
    puts "[ingest] replacement comment posted on PR ##{pr_number}"
  else
    puts "[ingest] WARN: could not post replacement comment: #{resp.code} #{resp.body}"
  end
end

# ── SUMMARY ────────────────────────────────────────────────────────────────────────────
puts "[ingest] ✅ Done. upserted=#{total_upserted} replaced=#{total_replaced} errors=#{errors.size}"
errors.each { |e| puts "  ✗ #{e}" }
exit(errors.any? ? 1 : 0)
