# frozen_string_literal: true

require_relative "test_helper"

class ProjectConfigTest < Minitest::Test
  DEFAULTS = { validation: { level: "static" }, sampling: { max_tokens: 8192 }, repair: { max_attempts: 3 } }.freeze

  def test_returns_defaults_without_workspace
    assert_equal DEFAULTS, Calvin::ProjectConfig.load(nil, defaults: DEFAULTS)
  end

  def test_returns_defaults_when_file_missing
    with_workspace(files: { "README.md" => "x" }) do |ws|
      assert_equal DEFAULTS, Calvin::ProjectConfig.load(ws, defaults: DEFAULTS)
    end
  end

  def test_overrides_project_keys
    yaml = "validation:\n  level: full\n"

    with_workspace(files: { Calvin::ProjectConfig::PATH => yaml }) do |ws|
      config = Calvin::ProjectConfig.load(ws, defaults: DEFAULTS)

      assert_equal "full", config.dig(:validation, :level)
    end
  end

  # Deep merge: una chiave non toccata dal progetto deve sopravvivere intatta.
  def test_deep_merge_preserves_untouched_keys
    yaml = "validation:\n  level: full\n"

    with_workspace(files: { Calvin::ProjectConfig::PATH => yaml }) do |ws|
      config = Calvin::ProjectConfig.load(ws, defaults: DEFAULTS)

      assert_equal false, config.dig(:validation).key?(:open_pr_when_red) # non presente nei DEFAULTS di test, ma la chiave level resta accanto alle altre eventuali
      assert_equal 8192, config.dig(:sampling, :max_tokens)
      assert_equal 3, config.dig(:repair, :max_attempts)
    end
  end

  # Un progetto non può alzare il proprio budget o cambiare il modello del motore.
  def test_engine_only_keys_are_ignored
    yaml = "repair:\n  max_attempts: 999\n  max_cost_usd: 100\nvalidation:\n  level: full\n"

    with_workspace(files: { Calvin::ProjectConfig::PATH => yaml }) do |ws|
      config = Calvin::ProjectConfig.load(ws, defaults: DEFAULTS)

      assert_equal 3, config.dig(:repair, :max_attempts), "repair è ENGINE_ONLY: non sovrascrivibile"
      assert_equal "full", config.dig(:validation, :level), "validation resta sovrascrivibile"
    end
  end

  def test_invalid_yaml_falls_back_to_defaults
    with_workspace(files: { Calvin::ProjectConfig::PATH => "- [unclosed\n" }) do |ws|
      assert_equal DEFAULTS, Calvin::ProjectConfig.load(ws, defaults: DEFAULTS)
    end
  end

  def test_empty_file_falls_back_to_defaults
    with_workspace(files: { Calvin::ProjectConfig::PATH => "\n\n" }) do |ws|
      assert_equal DEFAULTS, Calvin::ProjectConfig.load(ws, defaults: DEFAULTS)
    end
  end

  def test_non_hash_yaml_falls_back_to_defaults
    with_workspace(files: { Calvin::ProjectConfig::PATH => "- a\n- b\n" }) do |ws|
      assert_equal DEFAULTS, Calvin::ProjectConfig.load(ws, defaults: DEFAULTS)
    end
  end

  # Se il file non c'è nella root primaria ma c'è in quella di root_workspace (fallback),
  # va comunque trovato — è il caso "monorepo bootstrap sbaglia la root".
  def test_falls_back_to_root_workspace_when_primary_lacks_the_file
    yaml = "validation:\n  level: full\n"

    with_workspace(files: {}, repo_root: "backend/api") do |primary|
      with_workspace(files: { Calvin::ProjectConfig::PATH => yaml }) do |root_ws|
        config = Calvin::ProjectConfig.load(primary, root_workspace: root_ws, defaults: DEFAULTS)

        assert_equal "full", config.dig(:validation, :level)
      end
    end
  end

  def test_primary_wins_over_root_workspace_fallback
    primary_yaml = "validation:\n  level: full\n"
    root_yaml    = "validation:\n  level: static\n"

    with_workspace(files: { Calvin::ProjectConfig::PATH => primary_yaml }) do |primary|
      with_workspace(files: { Calvin::ProjectConfig::PATH => root_yaml }) do |root_ws|
        config = Calvin::ProjectConfig.load(primary, root_workspace: root_ws, defaults: DEFAULTS)

        assert_equal "full", config.dig(:validation, :level)
      end
    end
  end

  # ── root_for ──────────────────────────────────────────────────────────────────

  def test_root_for_prefers_explicit_root
    config = { root: "backend/api", repo: { roots: { rails: "other" } } }

    assert_equal "backend/api", Calvin::ProjectConfig.root_for(config, stack: "rails")
  end

  def test_root_for_falls_back_to_repo_roots_by_stack
    config = { repo: { roots: { rails: "backend/api" } } }

    assert_equal "backend/api", Calvin::ProjectConfig.root_for(config, stack: "rails")
  end

  def test_root_for_returns_empty_string_when_nothing_declared
    assert_equal "", Calvin::ProjectConfig.root_for({}, stack: "rails")
  end
end
