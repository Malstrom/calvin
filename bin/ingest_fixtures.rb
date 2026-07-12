#!/usr/bin/env ruby
# frozen_string_literal: true
# Entry point per l'ingestion di fixtures e test_helper.
#
# Triggered da calvin-ingest-fixtures.yml su push a main di synca
# quando vengono modificati test/fixtures/** o test/test_helper.rb.
#
# Usage:
#   ruby bin/ingest_fixtures.rb --repo Malstrom/synca --all
#   ruby bin/ingest_fixtures.rb --repo Malstrom/synca --changed "test/fixtures/users.yml,test/test_helper.rb"
#
# Flusso:
#   1. FixturesFetcher legge i file da main del repo target
#   2. Per ogni chunk: embedding -> upsert in Supabase (idempotente)
#   3. Nessun dedup semantico: le fixtures si identificano per source_path

require "optparse"
require_relative "../lib/boot"
require_relative "../lib/ingestion/fixtures_fetcher"
require_relative "../lib/ingestion/embedder"
require_relative "../lib/ingestion/supabase_store"

# ── CLI ──────────────────────────────────────────────────────────────────────
options = { all: false }
OptionParser.new do |opts|
  opts.banner = "Usage: ruby bin/ingest_fixtures.rb --repo OWNER/REPO [--all | --changed PATHS]"
  opts.on("--repo REPO",     "Target repo (e.g. Malstrom/synca)")              { |v| options[:repo]    = v }
  opts.on("--all",           "Ingest tutti i fixtures (ingest iniziale)")       {     options[:all]    = true }
  opts.on("--changed PATHS", "Percorsi CSV dei file cambiati (reingest selettivo)") { |v| options[:changed] = v.split(",").map(&:strip) }
end.parse!

raise "--repo is required"            unless options[:repo]
raise "--all oppure --changed richiesto" unless options[:all] || options[:changed]

repo          = options[:repo]
changed_paths = options[:all] ? nil : options[:changed]
store         = Ingestion::SupabaseStore.new
embedder      = Ingestion::Embedder.new

total_upserted = 0
errors         = []

# ── FETCH ────────────────────────────────────────────────────────────────────
label = changed_paths ? "#{changed_paths.size} file(s) cambiati" : "tutti i file"
puts "[ingest_fixtures] Fetching da #{repo} (#{label})..."

chunks = Ingestion::FixturesFetcher.from_repo(repo, changed_paths: changed_paths)

if chunks.empty?
  puts "[ingest_fixtures] WARN: nessun file da ingestare — nothing to do"
  exit 0
end

puts "[ingest_fixtures] #{chunks.size} chunk(s) da processare"
puts ""

# ── PROCESS ──────────────────────────────────────────────────────────────────
chunks.each do |chunk|
  puts "[ingest_fixtures] ── #{chunk[:source_path]} [#{chunk[:source_type]}] ──"

  begin
    embedding = embedder.embed(chunk[:content])

    store.upsert(
      repo:        repo,
      source_type: chunk[:source_type],
      source_path: chunk[:source_path],
      content:     chunk[:content],
      embedding:   embedding
    )

    puts "[ingest_fixtures] → upserted (#{chunk[:content].bytesize}B)"
    total_upserted += 1

  rescue => e
    puts "[ingest_fixtures] → ERROR: #{e.message}"
    errors << "#{chunk[:source_path]}: #{e.message}"
  end

  puts ""
end

# ── SUMMARY ──────────────────────────────────────────────────────────────────
puts "[ingest_fixtures] ✅ Done. upserted=#{total_upserted} errors=#{errors.size}"
errors.each { |e| puts "  ✗ #{e}" }
exit(errors.any? ? 1 : 0)
