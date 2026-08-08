# frozen_string_literal: true

require_relative "test_helper"

class ProjectProfileTest < Minitest::Test
  # ── default: un Rails standard non ha bisogno di scrivere project.yml ──────────

  def test_defaults_when_no_profile_file
    with_workspace do |ws|
      profile = Calvin::ProjectProfile.load(workspace: ws)

      assert profile.defaults?
      assert_equal "", profile.app_root
      assert_equal "minitest", profile.test_framework
      assert_equal "bin/rails test", profile.test_command
      assert_equal "bin/rails db:migrate", profile.gate_command(:migrate)
      assert_empty profile.forbidden_patterns
      refute profile.conventions?
    end
  end

  def test_default_path_map_derives_test_from_source
    with_workspace do |ws|
      profile = Calvin::ProjectProfile.load(workspace: ws)

      assert_equal "test/services/foo_test.rb", profile.test_path_for("app/services/foo.rb")
      assert_equal "test/models/user_test.rb",  profile.test_path_for("app/models/user.rb")
      assert_nil profile.test_path_for("config/routes.rb")
      assert_nil profile.test_path_for("db/migrate/20260101000000_x.rb")
    end
  end

  # ── profilo esplicito ─────────────────────────────────────────────────────────

  def test_reads_app_root_and_commands_from_profile
    with_workspace(files: { ".calvin/project.yml" => <<~YML }) do |ws|
      app_root: backend/api
      test:
        framework: rspec
        command: bundle exec rspec
      gates:
        migrate: bin/rails db:prepare
    YML
      profile = Calvin::ProjectProfile.load(workspace: ws)

      refute profile.defaults?
      assert_equal "backend/api", profile.app_root
      assert_equal "rspec", profile.test_framework
      assert_equal "bundle exec rspec", profile.test_command
      assert_equal "bin/rails db:prepare", profile.gate_command(:migrate)
      # i gate non dichiarati restano ai default generici
      assert_equal "bin/rails zeitwerk:check", profile.gate_command(:zeitwerk)
    end
  end

  def test_app_root_trailing_slash_is_normalised
    with_workspace(files: { ".calvin/project.yml" => "app_root: backend/api/\n" }) do |ws|
      assert_equal "backend/api", Calvin::ProjectProfile.load(workspace: ws).app_root
    end
  end

  def test_rspec_style_path_map
    with_workspace(files: { ".calvin/project.yml" => <<~YML }) do |ws|
      test:
        path_map:
          - from: 'app/(.*)\\.rb'
            to:   'spec/\\1_spec.rb'
    YML
      profile = Calvin::ProjectProfile.load(workspace: ws)

      assert_equal "spec/services/foo_spec.rb", profile.test_path_for("app/services/foo.rb")
    end
  end

  def test_empty_gate_command_disables_the_gate
    with_workspace(files: { ".calvin/project.yml" => "gates:\n  zeitwerk: ''\n" }) do |ws|
      assert_nil Calvin::ProjectProfile.load(workspace: ws).gate_command(:zeitwerk)
    end
  end

  # ── forbidden_patterns: la regola di synca esce dal motore ────────────────────

  def test_forbidden_patterns_flag_matching_files
    with_workspace(files: { ".calvin/project.yml" => <<~YML }) do |ws|
      forbidden_patterns:
        - paths: "app/models/**"
          pattern: '^\\s*validates?\\s'
          message: "i model del progetto sono strutture dati"
    YML
      profile = Calvin::ProjectProfile.load(workspace: ws)

      hits = profile.forbidden_matches("app/models/user.rb", "class User\n  validates :email\nend\n")
      assert_equal 1, hits.size
      assert_includes hits.first, "strutture dati"

      # stesso contenuto, path fuori dal glob → nessuna violazione
      assert_empty profile.forbidden_matches("app/services/user_service.rb", "  validates :email\n")
      # path nel glob, contenuto pulito → nessuna violazione
      assert_empty profile.forbidden_matches("app/models/user.rb", "class User\nend\n")
    end
  end

  def test_forbidden_pattern_glob_crosses_directories
    with_workspace(files: { ".calvin/project.yml" => <<~YML }) do |ws|
      forbidden_patterns:
        - paths: "app/models/**"
          pattern: 'validates'
          message: "no"
    YML
      profile = Calvin::ProjectProfile.load(workspace: ws)

      refute_empty profile.forbidden_matches("app/models/concerns/x.rb", "validates :a\n")
    end
  end

  def test_invalid_regex_is_skipped_not_fatal
    with_workspace(files: { ".calvin/project.yml" => <<~YML }) do |ws|
      forbidden_patterns:
        - paths: "app/**"
          pattern: '([unclosed'
          message: "boom"
    YML
      profile = Calvin::ProjectProfile.load(workspace: ws)

      assert_empty profile.forbidden_matches("app/models/user.rb", "qualsiasi cosa")
    end
  end

  # ── conventions.md ────────────────────────────────────────────────────────────

  def test_conventions_are_loaded
    with_workspace(files: { ".calvin/conventions.md" => "# Regole\n\n- I controller sono thin.\n" }) do |ws|
      profile = Calvin::ProjectProfile.load(workspace: ws)

      assert profile.conventions?
      assert_includes profile.conventions, "controller sono thin"
    end
  end

  def test_conventions_are_truncated_to_budget
    limit = Calvin::CONFIG.dig(:conventions, :max_bytes) || 8192
    with_workspace(files: { ".calvin/conventions.md" => "x" * (limit + 500) }) do |ws|
      profile = Calvin::ProjectProfile.load(workspace: ws)

      assert profile.conventions.bytesize <= limit + 100, "troncamento oltre il budget"
      assert_includes profile.conventions, "troncate"
    end
  end

  # ── robustezza ────────────────────────────────────────────────────────────────

  def test_malformed_yaml_falls_back_to_defaults
    with_workspace(files: { ".calvin/project.yml" => "app_root: [unclosed\n" }) do |ws|
      profile = Calvin::ProjectProfile.load(workspace: ws)

      assert_equal "", profile.app_root
      assert_equal "bin/rails test", profile.test_command
    end
  end

  def test_legacy_repo_roots_fallback_when_profile_absent
    with_workspace do |ws|
      profile = Calvin::ProjectProfile.load(workspace: ws, labels: ["rails"])

      assert_equal Calvin::REPO_ROOTS["rails"], profile.app_root
    end
  end

  def test_profile_app_root_wins_over_legacy_labels
    with_workspace(files: { ".calvin/project.yml" => "app_root: ''\n" }) do |ws|
      profile = Calvin::ProjectProfile.load(workspace: ws, labels: ["rails"])

      assert_equal "", profile.app_root
    end
  end

  def test_falls_back_to_github_when_clone_unavailable
    reader = FakeReader.new(files: { ".calvin/project.yml" => "app_root: srv\n" })
    profile = Calvin::ProjectProfile.load(workspace: nil, github: reader)

    assert_equal "srv", profile.app_root
  end
end
