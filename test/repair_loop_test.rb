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
end
