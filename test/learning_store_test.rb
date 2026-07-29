# frozen_string_literal: true

require_relative "test_helper"

class LearningStoreTest < Minitest::Test
  def teardown
    ENV.delete("SUPABASE_URL")
    ENV.delete("SUPABASE_SERVICE_KEY")
  end

  # ── configurazione ────────────────────────────────────────────────────────────

  def test_not_configured_without_env
    refute Calvin::LearningStore.configured?
  end

  def test_configured_with_env
    with_supabase_env { assert Calvin::LearningStore.configured? }
  end

  # La telemetria non deve mai far fallire un run: senza Supabase si logga e si prosegue.
  def test_record_without_supabase_returns_zero
    assert_equal 0, Calvin::LearningStore.record([{ gate: "syntax", signature: "syntax/unexpected_end" }])
  end

  def test_record_with_empty_events_is_a_noop
    with_supabase_env { assert_equal 0, Calvin::LearningStore.record([]) }
  end

  def test_aggregate_raises_without_supabase
    assert_raises(RuntimeError) { Calvin::LearningStore.aggregate }
  end

  # ── summarize: il cuore di bin/learn.rb ───────────────────────────────────────

  def test_groups_by_signature_and_scope
    rows = [
      row("rubocop/Style/Documentation", "service", fixed: true),
      row("rubocop/Style/Documentation", "service", fixed: true),
      row("rubocop/Style/Documentation", "service", fixed: false),
      row("structural/lost_definitions", "model",   fixed: false),
      row("rubocop/Style/Documentation", "model",   fixed: true)
    ]

    result = Calvin::LearningStore.summarize(rows)

    top = result.first
    assert_equal "rubocop/Style/Documentation", top[:signature]
    assert_equal "service", top[:scope]
    assert_equal 3, top[:occurrences]
    assert_equal 2, top[:fixed_count]

    # Lo stesso errore in uno scope diverso resta una voce distinta: dice dove intervenire.
    assert_equal 3, result.size
    assert_includes result.map { |r| [r[:signature], r[:scope]] }, ["rubocop/Style/Documentation", "model"]
  end

  def test_sorted_by_frequency_desc
    rows = [row("a", "service")] + Array.new(4) { row("b", "model") }

    assert_equal %w[b a], Calvin::LearningStore.summarize(rows).map { |r| r[:signature] }
  end

  def test_collects_distinct_paths
    rows = [
      row("structural/lost_definitions", "model", path: "app/models/user.rb"),
      row("structural/lost_definitions", "model", path: "app/models/order.rb"),
      row("structural/lost_definitions", "model", path: "app/models/user.rb")
    ]

    assert_equal ["app/models/user.rb", "app/models/order.rb"],
                 Calvin::LearningStore.summarize(rows).first[:paths]
  end

  def test_summarize_handles_empty_input
    assert_empty Calvin::LearningStore.summarize([])
    assert_empty Calvin::LearningStore.summarize(nil)
  end

  # ── classify: la decisione operativa ──────────────────────────────────────────

  # Calvin lo sa risolvere, ma solo dopo aver sbagliato: va prevenuto.
  def test_frequent_and_always_fixed_is_prevent
    assert_equal :prevent, classify(occurrences: 8, fixed_count: 8)
  end

  # Il repair non ce la fa: serve una decisione umana.
  def test_frequent_and_never_fixed_is_human
    assert_equal :human, classify(occurrences: 6, fixed_count: 0)
  end

  def test_mixed_outcome_is_watch
    assert_equal :watch, classify(occurrences: 10, fixed_count: 5)
  end

  # Un errore capitato una volta non è un pattern.
  def test_rare_is_noise_regardless_of_outcome
    assert_equal :noise, classify(occurrences: 2, fixed_count: 2)
    assert_equal :noise, classify(occurrences: 1, fixed_count: 0)
  end

  def test_min_occurrences_is_configurable
    assert_equal :prevent, classify({ occurrences: 2, fixed_count: 2 }, min_occurrences: 2)
  end

  private

  def classify(entry = nil, occurrences: nil, fixed_count: nil, min_occurrences: 3)
    entry ||= { occurrences: occurrences, fixed_count: fixed_count }
    Calvin::LearningStore.classify(entry, min_occurrences: min_occurrences)
  end

  def row(signature, scope, fixed: false, path: nil, gate: nil)
    {
      "signature"  => signature,
      "scope"      => scope,
      "gate"       => gate || signature.split("/").first,
      "path"       => path,
      "fixed"      => fixed,
      "created_at" => "2026-07-29T10:00:00Z"
    }
  end

  def with_supabase_env
    ENV["SUPABASE_URL"]         = "https://example.supabase.co"
    ENV["SUPABASE_SERVICE_KEY"] = "key"
    yield
  end
end
