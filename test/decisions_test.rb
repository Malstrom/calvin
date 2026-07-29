# frozen_string_literal: true

require_relative "test_helper"

class DecisionsTest < Minitest::Test
  SIMPLE = <<~YAML
    - "Le API pubbliche versionano (api/v1), le interne no."
    - "Order#status è deprecato: usare Order#state."
  YAML

  SCOPED = <<~YAML
    - "Vale sempre: nessun secret nel codice."
    - text: "I job di notifica usano la coda :mailers."
      scope: job
    - text: "I controller non fanno query dirette."
      scope: controller
  YAML

  # ── caricamento ───────────────────────────────────────────────────────────────

  def test_loads_plain_list
    with_decisions(SIMPLE) do |set|
      assert_equal 2, set.size
      assert set.any?
      assert_equal :file, set.source
    end
  end

  def test_empty_without_workspace
    set = Calvin::Decisions.load(nil)

    refute set.any?
    assert_equal :none, set.source
  end

  def test_empty_when_file_missing
    with_workspace(files: { "README.md" => "x" }) do |ws|
      refute Calvin::Decisions.load(ws).any?
    end
  end

  def test_empty_when_file_blank
    with_decisions("\n\n") { |set| refute set.any? }
  end

  # Un YAML rotto nel repo target non deve far fallire il run.
  def test_invalid_yaml_is_ignored
    with_decisions("- [unclosed\n") do |set|
      refute set.any?
      assert_equal :none, set.source
    end
  end

  def test_accepts_hash_with_decisions_key
    yaml = "version: 1\ndecisions:\n  - \"Prima regola.\"\n"

    with_decisions(yaml) { |set| assert_equal 1, set.size }
  end

  def test_skips_empty_entries
    with_decisions("- \"Valida.\"\n- \"\"\n- \"   \"\n") { |set| assert_equal 1, set.size }
  end

  # Il formato del log di decisioni che il template calvin_context/decisions.yml già usava
  # deve continuare a funzionare: `decision` invece di `text`.
  def test_accepts_decision_log_format
    yaml = <<~YAML
      decisions:
        - date: "2026-07-15"
          decision: "Use dry-validation for all input contracts"
          rationale: "Consistent validation layer, already in the stack"
          source: "PR #42"
          scope: contract
    YAML

    with_decisions(yaml) do |set|
      text = set.for_scopes(["contract"]).first

      assert_includes text, "dry-validation"
      # Il rationale entra nel prompt: il "perché" impedisce generalizzazioni fuori dominio.
      assert_includes text, "already in the stack"
    end
  end

  def test_decision_without_rationale_has_no_trailing_dash
    with_decisions("- decision: \"Solo la decisione.\"\n") do |set|
      refute_includes set.for_scopes([]).first, "—"
    end
  end

  # ── selezione per scope ───────────────────────────────────────────────────────

  # Le decisioni senza scope valgono sempre; quelle con scope solo per i layer toccati.
  def test_for_scopes_returns_globals_plus_matching
    with_decisions(SCOPED) do |set|
      texts = set.for_scopes(["job"])

      assert_equal 2, texts.size
      assert_includes texts.join, "nessun secret"
      assert_includes texts.join, ":mailers"
      refute_includes texts.join, "query dirette"
    end
  end

  def test_for_scopes_with_no_match_returns_only_globals
    with_decisions(SCOPED) do |set|
      assert_equal ["Vale sempre: nessun secret nel codice."], set.for_scopes(["serializer"])
    end
  end

  def test_for_scopes_ignores_nil_entries
    with_decisions(SCOPED) { |set| assert_equal 1, set.for_scopes([nil]).size }
  end

  # ── sezione di prompt ─────────────────────────────────────────────────────────

  def test_prompt_section_lists_all_when_no_scopes
    with_decisions(SCOPED) do |set|
      section = set.to_prompt_section

      assert_includes section, "## Project decisions"
      assert_includes section, "- Vale sempre: nessun secret nel codice."
      assert_includes section, "- I job di notifica usano la coda :mailers."
      assert_includes section, "- I controller non fanno query dirette."
    end
  end

  def test_prompt_section_is_nil_when_nothing_applies
    with_decisions("- text: \"Solo per i job.\"\n  scope: job\n") do |set|
      assert_nil set.to_prompt_section(scopes: ["model"])
    end
  end

  def test_prompt_section_nil_for_empty_set
    assert_nil Calvin::Decisions::EMPTY.to_prompt_section
  end

  # Il budget taglia dalla fine, senza riordinare: l'ordine è quello scelto dall'umano.
  def test_budget_truncates_from_the_end
    yaml = (1..10).map { |i| "- \"Decisione numero #{i} con un po' di testo per occupare spazio.\"" }.join("\n")

    with_decisions(yaml) do |set|
      section = set.to_prompt_section(budget_bytes: 150)

      assert_includes section, "Decisione numero 1"
      refute_includes section, "Decisione numero 10"
    end
  end

  def test_prompt_section_mentions_legacy_override
    with_decisions(SIMPLE) do |set|
      assert_includes set.to_prompt_section, "legacy"
    end
  end

  private

  def with_decisions(yaml, &block)
    with_workspace(files: { Calvin::Decisions::PATH => yaml }) do |ws|
      block.call(Calvin::Decisions.load(ws))
    end
  end
end
