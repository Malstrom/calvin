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
#   3. Per ogni bullet: embedding -> dedup check -> upsert o skip
#   4. Log completo di ogni chunk (contenuto intero + esito)
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

# ── CLI ──────────────────────────────────────────────────────────────────────────────
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

total_upserted = 0
total_skipped  = 0
errors         = []

# ── FETCH RULES ─────────────────────────────────────────────────────────────────────
puts "[ingest] Fetching rules from PR ##{pr_number} in #{repo}..."

chunks = Ingestion::RulesFetcher.from_pr(repo, pr_number)

if chunks.empty?
  puts "[ingest] WARN: no checked rules found in PR ##{pr_number} — nothing to ingest"
  exit 0
end

puts "[ingest] #{chunks.size} rule(s) to process"
puts ""

# ── PROCESS EACH CHUNK ───────────────────────────────────────────────────────────────────
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
      puts "[ingest] → SKIPPED (similar chunk exists)"
      puts "[ingest]   match:    #{existing['source_path']} (similarity=#{format('%.4f', existing['similarity'])})"
      puts "[ingest]   existing: #{existing['content'].to_s.lines.map(&:rstrip).join("\n[ingest]             ")}"
      total_skipped += 1
      next
    end

    # — upsert ────────────────────────────────────────────────────────────────────────────────
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

# ── SUMMARY ──────────────────────────────────────────────────────────────────────────────
puts "[ingest] ✅ Done. upserted=#{total_upserted} skipped=#{total_skipped} errors=#{errors.size}"
errors.each { |e| puts "  ✗ #{e}" }
exit(errors.any? ? 1 : 0)
