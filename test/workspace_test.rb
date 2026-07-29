# frozen_string_literal: true

require_relative "test_helper"

class WorkspaceTest < Minitest::Test
  FILES = {
    "app/models/user.rb"   => "class User\n  has_many :sessions\nend\n",
    "app/models/token.rb"  => "class Token\nend\n",
    "config/routes.rb"     => "Rails.application.routes.draw do\n  get \"auth/me\"\nend\n"
  }.freeze

  def test_reads_files_relative_to_repo_root
    with_workspace(files: FILES, repo_root: "backend/api") do |ws|
      assert ws.available?
      assert_includes ws.read("app/models/user.rb"), "has_many :sessions"
    end
  end

  def test_read_returns_nil_for_missing_file
    with_workspace(files: FILES) do |ws|
      assert_nil ws.read("app/models/nope.rb")
    end
  end

  def test_lists_directory_sorted
    with_workspace(files: FILES) do |ws|
      assert_equal %w[token.rb user.rb], ws.list("app/models")
    end
  end

  def test_list_returns_empty_for_missing_directory
    with_workspace(files: FILES) do |ws|
      assert_empty ws.list("app/nope")
    end
  end

  def test_grep_returns_path_line_and_content
    with_workspace(files: FILES) do |ws|
      output = ws.grep("has_many", "app/models")

      assert_includes output, "app/models/user.rb:2:"
      assert_includes output, "has_many :sessions"
      refute_includes output, ws.root, "i path devono essere relativi al progetto"
    end
  end

  def test_grep_is_case_insensitive
    with_workspace(files: FILES) do |ws|
      assert_includes ws.grep("HAS_MANY", "app/models/user.rb"), "has_many"
    end
  end

  def test_grep_reports_no_matches_as_error_string
    with_workspace(files: FILES) do |ws|
      assert ws.grep("inesistente", "app/models").start_with?("ERROR:")
    end
  end

  def test_write_creates_intermediate_directories
    with_workspace(files: FILES) do |ws|
      ws.write("app/services/new/deep_service.rb", "class DeepService; end\n")

      assert_includes ws.read("app/services/new/deep_service.rb"), "DeepService"
    end
  end

  def test_latest_migration_version
    with_workspace(files: { "db/migrate/20260101000000_a.rb" => "", "db/migrate/20260202000000_b.rb" => "" }) do |ws|
      assert_equal "20260202000000", ws.latest_migration_version
    end
  end

  # Un path prodotto dal modello non deve poter uscire dal repo target.
  def test_rejects_path_traversal
    with_workspace(files: FILES) do |ws|
      assert_raises(Calvin::Workspace::PathEscape) { ws.read("../../etc/passwd") }
      assert_raises(Calvin::Workspace::PathEscape) { ws.write("/etc/passwd", "x") }
    end
  end

  def test_unavailable_when_directory_missing
    ws = Calvin::Workspace.new(target_path: "/tmp/calvin-does-not-exist-#{Process.pid}")

    refute ws.available?
  end
end
