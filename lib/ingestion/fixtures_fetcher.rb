# frozen_string_literal: true
# FixturesFetcher — legge fixtures e test_helper.rb
# dal repo target e produce un chunk per file pronto per l'embedding.
#
# I path sono configurabili via config/calvin.yml:
#   project:
#     fixtures_dir:      backend/api/test/fixtures
#     test_helper_path:  backend/api/test/test_helper.rb
#
# source_type: "fixture"     → ogni file sotto fixtures_dir/*.yml
# source_type: "test_helper" → test_helper_path (chunk singolo)
#
# Idempotente: l'upsert in Supabase è su unique(repo, source_path).
# Chunking: un chunk per file — le fixtures Rails sono già piccole.

require "octokit"
require "base64"

module Ingestion
  class FixturesFetcher
    def self.fixtures_dir
      Calvin.config.dig(:project, :fixtures_dir) || "test/fixtures"
    end

    def self.test_helper_path
      Calvin.config.dig(:project, :test_helper_path) || "test/test_helper.rb"
    end

    def self.from_repo(repo, ref: "main", changed_paths: nil)
      new(repo, ref: ref, changed_paths: changed_paths).fetch
    end

    def initialize(repo, ref: "main", changed_paths: nil)
      @repo             = repo
      @ref              = ref
      @changed_paths    = changed_paths
      @fixtures_dir     = self.class.fixtures_dir
      @test_helper_path = self.class.test_helper_path
      @client           = Octokit::Client.new(access_token: ENV.fetch("GITHUB_TOKEN"))
    end

    def fetch
      chunks = []
      chunks.concat(fetch_fixtures)
      chunks.concat(fetch_test_helper)
      chunks
    end

    private

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
      entries = @client.contents(@repo, path: @fixtures_dir, ref: @ref)
      entries
        .select { |e| e[:type] == "file" && e[:name].end_with?(".yml") }
        .map    { |e| e[:path] }
    rescue Octokit::NotFound
      Calvin::LOG.warn "FixturesFetcher: #{@fixtures_dir} not found in #{@repo}"
      []
    end

    def fetch_test_helper
      if @changed_paths && !@changed_paths.include?(@test_helper_path)
        Calvin::LOG.info "FixturesFetcher: test_helper.rb unchanged — skipping"
        return []
      end

      content = fetch_file(@test_helper_path)
      return [] if content.nil?

      Calvin::LOG.info "FixturesFetcher: fetched #{@test_helper_path} (#{content.bytesize}B)"
      [{
        source_type: "test_helper",
        source_path: "test_helper",
        content:     content
      }]
    end

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
