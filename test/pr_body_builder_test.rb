# frozen_string_literal: true

require_relative "test_helper"

class PrBodyBuilderTest < Minitest::Test
  USAGE         = { "prompt_tokens" => 1000, "completion_tokens" => 500, "total_tokens" => 1500 }.freeze
  USAGE_EXPLORE = { "prompt_tokens" => 4000, "completion_tokens" => 300, "cached_tokens" => 2000 }.freeze

  def test_body_contains_description_signature_and_closes
    body = build(description: "## What this does\n\nAggiunge l'endpoint.")

    assert_includes body, "Aggiunge l'endpoint."
    assert_includes body, "Closes #42"
    assert_includes body, Calvin::MODEL.to_s
  end

  def test_body_without_description
    assert_includes build(description: nil), "_No description provided._"
  end

  def test_token_table_reports_both_phases
    body = build(usage_explore: USAGE_EXPLORE, turns: 7)

    assert_includes body, "### 📊 Token usage"
    assert_includes body, "explore (7t)"
    assert_includes body, "implement"
    assert_includes body, "**totale**"
  end

  # Il costo usa lo sconto del 10% sui token cachati: 2000 cached su 4000 inviati.
  def test_cached_tokens_are_discounted
    body = build(usage_explore: USAGE_EXPLORE)

    assert_includes body, "2000 (50%)"
  end

  # ── sezione validazione ───────────────────────────────────────────────────────

  def test_green_validation_section_is_first
    body = build(validation: green_validation, repair_attempts: 0)

    assert body.start_with?("✅ **Validazione superata**"), body[0, 80]
  end

  def test_green_section_mentions_repair_attempts
    assert_includes build(validation: green_validation, repair_attempts: 2), "dopo 2 tentativo/i di repair"
  end

  def test_red_validation_section_warns_and_shows_output
    body = build(validation: red_validation, repair_attempts: 3)

    assert_includes body, "⚠️ **Validazione rossa sul gate `syntax`**"
    assert_includes body, "non** è pronta al merge"
    assert_includes body, "syntax error, unexpected end"
  end

  # Un backtick triplo dentro l'output del gate romperebbe il blocco di codice del body.
  def test_backticks_in_gate_output_are_neutralised
    validation = Calvin::Validator::Result.new(
      ok: false, stage: :rubocop, output: "offesa in ```ruby blocco```", failed_paths: []
    )

    body = build(validation: validation)

    refute_includes body.split("<details>").last.sub(/```\n/, ""), "```ruby"
  end

  def test_long_gate_output_is_truncated
    validation = Calvin::Validator::Result.new(
      ok: false, stage: :focused_test, output: "x" * 9000, failed_paths: []
    )

    body = build(validation: validation)

    assert_includes body, "(troncato)"
    assert_operator body.length, :<, 9000
  end

  def test_no_validation_section_when_absent
    body = build(validation: nil)

    refute_includes body, "Validazione"
  end

  private

  def green_validation
    Calvin::Validator::Result.new(ok: true, stage: :all, output: "ok", failed_paths: [])
  end

  def red_validation
    Calvin::Validator::Result.new(
      ok: false, stage: :syntax,
      output: "app/services/x.rb:3: syntax error, unexpected end", failed_paths: ["app/services/x.rb"]
    )
  end

  def build(**overrides)
    Calvin::PrBodyBuilder.build(
      **{
        issue:       Issue.build(number: 42, title: "Endpoint"),
        usage:       USAGE,
        description: "descrizione"
      }.merge(overrides)
    )
  end
end
