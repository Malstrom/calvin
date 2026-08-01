# frozen_string_literal: true

require_relative "test_helper"

class RepairLoopTest < Minitest::Test
  # Doppio del client Mistral: restituisce risposte predefinite e registra i prompt,
  # così i test verificano cosa viene mandato al modello senza chiamare l'API.
  class FakeMistral
    attr_reader :calls

    def initialize(responses)
      @responses = Array(responses)
      @calls     = []
    end

    def complete_messages(messages, temperature: nil, cache_key: nil)
      @calls << messages
      content = @responses.shift || ""
      { content: content, usage: { "prompt_tokens" => 100, "completion_tokens" => 50, "total_tokens" => 150 } }
    end
  end

  BROKEN = "class Broken\n  def call\nend\n"
  FIXED  = "# frozen_string_literal: true\n\nclass Broken\n  def call\n    true\n  end\nend\n"

  def test_repairs_syntax_error_and_returns_green
    files   = [{ path: "app/services/broken.rb", content: BROKEN }]
    mistral = FakeMistral.new(["FILE: app/services/broken.rb\n#{FIXED}"])

    result = repair(files, mistral)

    assert result[:validation].ok?, "atteso verde, ottenuto #{result[:validation].stage}"
    assert_equal 1, result[:attempts]
    assert_includes result[:files].first[:content], "true"
  end

  def test_gives_up_after_max_attempts_and_reports_red
    files   = [{ path: "app/services/broken.rb", content: BROKEN }]
    # Il modello continua a restituire codice rotto.
    mistral = FakeMistral.new(Array.new(5) { "FILE: app/services/broken.rb\n#{BROKEN}" })

    result = repair(files, mistral)

    refute result[:validation].ok?
    assert_equal Calvin::CONFIG.dig(:repair, :max_attempts), result[:attempts]
    assert_equal :syntax, result[:validation].stage
  end

  def test_sends_gate_name_and_error_output_to_the_model
    files   = [{ path: "app/services/broken.rb", content: BROKEN }]
    mistral = FakeMistral.new(["FILE: app/services/broken.rb\n#{FIXED}"])

    repair(files, mistral)

    user_message = mistral.calls.first.last[:content]
    assert_includes user_message, "## Failing gate"
    assert_includes user_message, "syntax"
    assert_includes user_message, "## Error output"
    assert_includes user_message, "app/services/broken.rb"
  end

  # Mandare al modello anche i file non coinvolti lo invita a riscriverli.
  def test_sends_only_the_files_involved_in_the_failure
    files = [
      { path: "app/services/broken.rb", content: BROKEN },
      { path: "app/services/healthy.rb", content: "# frozen_string_literal: true\n\nclass Healthy\n  def call = true\nend\n" }
    ]
    mistral = FakeMistral.new(["FILE: app/services/broken.rb\n#{FIXED}"])

    repair(files, mistral)

    user_message = mistral.calls.first.last[:content]
    assert_includes user_message, "FILE: app/services/broken.rb"
    refute_includes user_message, "FILE: app/services/healthy.rb"
  end

  def test_keeps_untouched_files_in_the_result
    files = [
      { path: "app/services/broken.rb", content: BROKEN },
      { path: "app/services/healthy.rb", content: "# frozen_string_literal: true\n\nclass Healthy\n  def call = true\nend\n" }
    ]
    mistral = FakeMistral.new(["FILE: app/services/broken.rb\n#{FIXED}"])

    result = repair(files, mistral)

    assert_equal 2, result[:files].size
    assert_includes result[:files].map { |f| f[:path] }, "app/services/healthy.rb"
  end

  def test_stops_when_model_returns_no_file_blocks
    files   = [{ path: "app/services/broken.rb", content: BROKEN }]
    mistral = FakeMistral.new(["Non riesco a correggerlo."])

    result = repair(files, mistral)

    refute result[:validation].ok?
    assert_equal 1, result[:attempts]
    assert_equal 1, mistral.calls.size, "senza FILE block non deve riprovare"
  end

  def test_returns_immediately_when_validation_is_already_green
    files      = [{ path: "app/services/ok.rb", content: "# frozen_string_literal: true\n\nclass Ok\n  def call = true\nend\n" }]
    validation = validate(files)
    mistral    = FakeMistral.new([])

    assert validation.ok?
    result = Calvin::RepairLoop.call(files: files, validation: validation, workspace: nil,
                                     github: nil, mistral: mistral)

    assert_equal 0, result[:attempts]
    assert_empty mistral.calls
  end

  # ── budget dedicato per i test generati ────────────────────────────────────────
  #
  # Un test ostinato non deve consumare il budget riservato al codice sorgente: quando
  # il gate rosso è focused_test su un path sotto test/, il tetto è
  # test_generation.max_attempts (2 di default), non repair.max_attempts (3).

  def test_uses_test_generation_budget_when_focused_test_fails_on_a_test_path
    files = [{ path: "test/services/foo_test.rb", content: "class FooTest; end\n" }]
    red_focused_test = Calvin::Validator::Result.new(
      ok: false, stage: :focused_test, output: "1 failure", failed_paths: ["test/services/foo_test.rb"]
    )
    # Il "fix" non risolve mai nulla: la rivalidazione (stubbata) resta sempre sullo
    # stesso gate rosso, così il loop consuma l'intero budget dedicato ai test.
    mistral = FakeMistral.new(Array.new(5) { "FILE: test/services/foo_test.rb\nclass FooTest; end\n" })

    result = with_stubbed_validation(red_focused_test) do
      Calvin::RepairLoop.call(files: files, validation: red_focused_test,
                             workspace: nil, github: nil, mistral: mistral)
    end

    refute result[:validation].ok?
    assert_equal Calvin::CONFIG.dig(:test_generation, :max_attempts), result[:attempts]
    assert_operator result[:attempts], :<, Calvin::CONFIG.dig(:repair, :max_attempts),
                    "il budget dei test deve essere più basso di quello generale, non uguale"
  end

  # Lo stesso gate (focused_test), ma su un path che NON è un test — non deve scattare
  # il budget dedicato: resta quello generale del repair sul codice sorgente.
  def test_general_budget_applies_to_focused_test_failures_outside_test_paths
    files = [{ path: "app/services/foo.rb", content: "class Foo; end\n" }]
    red_focused_test = Calvin::Validator::Result.new(
      ok: false, stage: :focused_test, output: "1 failure", failed_paths: ["app/services/foo.rb"]
    )
    mistral = FakeMistral.new(Array.new(5) { "FILE: app/services/foo.rb\nclass Foo; end\n" })

    result = with_stubbed_validation(red_focused_test) do
      Calvin::RepairLoop.call(files: files, validation: red_focused_test,
                             workspace: nil, github: nil, mistral: mistral)
    end

    assert_equal Calvin::CONFIG.dig(:repair, :max_attempts), result[:attempts]
  end

  def test_accumulates_usage
    files   = [{ path: "app/services/broken.rb", content: BROKEN }]
    mistral = FakeMistral.new(["FILE: app/services/broken.rb\n#{FIXED}"])

    result = repair(files, mistral)

    assert_equal 100, result[:usage]["prompt_tokens"]
    assert_equal 50,  result[:usage]["completion_tokens"]
  end

  private

  def repair(files, mistral)
    Calvin::RepairLoop.call(
      files:      files,
      validation: validate(files),
      workspace:  nil,
      github:     nil,
      mistral:    mistral
    )
  end

  def validate(files)
    Calvin::Validator.call(files: files, workspace: nil, github: nil)
  end

  # Simula una rivalidazione che resta sempre sullo stesso gate rosso, senza dover far
  # girare bin/rails test per davvero.
  def with_stubbed_validation(fixed_result, &block)
    with_stubbed_class_method(Calvin::Validator, :call, fixed_result, &block)
  end
end
