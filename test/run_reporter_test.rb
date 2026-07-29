# frozen_string_literal: true

require_relative "test_helper"

require "csv"

class RunReporterTest < Minitest::Test
  # Doppio di GitHubClient che tiene il CSV in memoria.
  class FakeGitHub
    attr_reader :committed

    def initialize(existing: nil)
      @existing  = existing
      @committed = nil
    end

    def get_file_content(_path, ref: nil) = @existing

    def commit_files_atomically(files, message:, branch:)
      @committed = { files: files, message: message, branch: branch }
      "sha"
    end
  end

  def test_writes_header_and_row
    github = FakeGitHub.new

    write(github)

    csv = CSV.parse(committed_content(github), headers: true)
    assert_equal Calvin::RunReporter::CSV_HEADER, csv.headers
    assert_equal 1, csv.size
    assert_equal "calvin", csv.first["workflow"]
    assert_equal "success", csv.first["status"]
  end

  def test_records_validation_columns
    github = FakeGitHub.new

    write(github, validation_ok: false, validation_stage: :focused_test, repair_attempts: 2)

    row = CSV.parse(committed_content(github), headers: true).first
    assert_equal "red", row["validation"]
    assert_equal "focused_test", row["validation_stage"]
    assert_equal "2", row["repair_attempts"]
  end

  def test_green_validation_is_recorded_as_green
    github = FakeGitHub.new

    write(github, validation_ok: true, validation_stage: :all, repair_attempts: 0)

    assert_equal "green", CSV.parse(committed_content(github), headers: true).first["validation"]
  end

  # Regressione: righe più corte dell'header producevano un CSV jagged.
  def test_pads_short_existing_rows_to_header_size
    short_row_csv = "#{Calvin::RunReporter::CSV_HEADER.join(',')}\n2026-01-01T00:00:00Z,calvin,1\n"
    github        = FakeGitHub.new(existing: short_row_csv)

    write(github)

    rows = CSV.parse(committed_content(github))
    rows.each do |row|
      assert_equal Calvin::RunReporter::CSV_HEADER.size, row.size, "riga con #{row.size} colonne: #{row.inspect}"
    end
  end

  def test_appends_to_existing_rows
    existing = "#{Calvin::RunReporter::CSV_HEADER.join(',')}\n#{(['x'] * Calvin::RunReporter::CSV_HEADER.size).join(',')}\n"
    github   = FakeGitHub.new(existing: existing)

    write(github)

    assert_equal 2, CSV.parse(committed_content(github), headers: true).size
  end

  def test_dry_run_writes_nothing
    github = FakeGitHub.new
    ENV["CALVIN_DRY_RUN"] = "true"

    write(github)

    assert_nil github.committed
  ensure
    ENV.delete("CALVIN_DRY_RUN")
  end

  def test_failure_in_github_is_swallowed
    broken = Class.new do
      def get_file_content(*) = raise("boom")
    end.new

    # Il reporter non deve mai far fallire il run per un problema di reporting.
    write(broken)
  end

  private

  def write(github, **overrides)
    Calvin::RunReporter.write(
      **{
        github:   github,
        workflow: "calvin",
        ref:      42,
        model:    "codestral-latest",
        usage:    { "prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150 },
        status:   :success
      }.merge(overrides)
    )
  end

  def committed_content(github)
    refute_nil github.committed, "nessun commit registrato"
    github.committed[:files].first[:content]
  end
end
