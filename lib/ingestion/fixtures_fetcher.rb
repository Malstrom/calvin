# frozen_string_literal: true
# FixturesFetcher — legge test/fixtures/*.yml e test/test_helper.rb
# dal repo target e produce un chunk per file pronto per l'embedding.
#
# source_type: "fixture"     → ogni file sotto test/fixtures/*.yml
# source_type: "test_helper" → test/test_helper.rb (chunk singolo)
#
# Ingestion::FixturesFetcher.from_repo("Malstrom/synca")
# => [
#   { source_type: "fixture",     source_path: "fixture/users.yml",       content: "..." },
#   { source_type: "fixture",     source_path: "fixture/magic_links.yml", content: "..." },
#   { source_type: "test_helper", source_path: "test_helper",             content: "..." },
# ]
#
# Con changed_paths: reingesce solo i file presenti nella lista.
# Con changed_paths: nil: reingesce tutto (ingest iniziale).
#
# Idempotente: l'upsert in Supabase è su unique(repo, source_path).
# Chunking: un chunk per file — le fixtures Rails sono già piccole.

require "octokit"
require "base64"

module Ingestion
  class FixturesFetcher
    FIXTURES_DIR     = "test/fixtures"
    TEST_HELPER_PATH = "test/test_helper.rb"

    def self.from_repo(repo, ref: "main", changed_paths: nil)
      new(repo, ref: ref, changed_paths: changed_paths).fetch
    end

    def initialize(repo, ref: "main", changed_paths: nil)
      @repo          = repo
      @ref           = ref
      @changed_paths = changed_paths
      @client        = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
    end

    def fetch
      chunks = []
      chunks.concat(fetch_fixtures)
      chunks.concat(fetch_test_helper)
      chunks
    end

    private

    # ── Fixtures ─────────────────────────────────────────────────────────────

    def fetch_fixtures
      all_paths = list_fixture_files

      paths = if @changed_paths
        all_paths.select { |p| @changed_paths.include?(p) }
      else
        all_paths
      end

      if paths.empty?
        Calvin::LOG.info "FixturesFetcher: no fixture files to ingest"
        return []
      end

      Calvin::LOG.info "FixturesFetcher: #{paths.size} fixture file(s) to process"

      paths.filter_map do |path|
        content = fetch_file(path)
        next if content.nil?

        Calvin::LOG.info "FixturesFetcher: fetched #{path} (#{content.bytesize}B)"
        {
          source_type: "fixture",
          source_path: "fixture/#{File.basename(path)}",
          content:     content
        }
      end
    end

    def list_fixture_files
      entries = @client.contents(@repo, path: FIXTURES_DIR, ref: @ref)
      entries
        .select { |e| e[:type] == "file" && e[:name].end_with?(".yml") }
        .map    { |e| e[:path] }
    rescue Octokit::NotFound
      Calvin::LOG.warn "FixturesFetcher: #{FIXTURES_DIR} not found in #{@repo}"
      []
    end

    # ── Test helper ──────────────────────────────────────────────────────────

    def fetch_test_helper
      if @changed_paths && !@changed_paths.include?(TEST_HELPER_PATH)
        Calvin::LOG.info "FixturesFetcher: test_helper.rb unchanged — skipping"
        return []
      end

      content = fetch_file(TEST_HELPER_PATH)
      return [] if content.nil?

      Calvin::LOG.info "FixturesFetcher: fetched #{TEST_HELPER_PATH} (#{content.bytesize}B)"
      [{
        source_type: "test_helper",
        source_path: "test_helper",
        content:     content
      }]
    end

    # ── Helpers ──────────────────────────────────────────────────────────────

    def fetch_file(path)
      blob    = @client.contents(@repo, path: path, ref: @ref)
      encoded = blob[:content].to_s.gsub("\n", "")
      Base64.decode64(encoded).force_encoding("UTF-8")
    rescue Octokit::NotFound
      Calvin::LOG.warn "FixturesFetcher: #{path} not found — skipped"
      nil
    end
  end
end
