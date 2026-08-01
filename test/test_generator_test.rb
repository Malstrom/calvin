# frozen_string_literal: true

require_relative "test_helper"

class TestGeneratorTest < Minitest::Test
  # Doppio del client Mistral: risponde in sequenza, registra i messaggi ricevuti.
  class FakeMistral
    attr_reader :calls

    def initialize(responses)
      @responses = Array(responses)
      @calls     = []
    end

    def complete_messages(messages, temperature: nil, cache_key: nil)
      @calls << messages
      content = @responses.shift || ""
      { content: content, usage: { "prompt_tokens" => 80, "completion_tokens" => 40 } }
    end
  end

  SERVICE = { path: "app/services/magic_link_service.rb", content: "# frozen_string_literal: true\n\nclass MagicLinkService\nend\n" }.freeze

  def test_disabled_by_default_returns_nothing
    mistral = FakeMistral.new([])

    result = Calvin::TestGenerator.call(files: [SERVICE], reader: FakeReader.new, mistral: mistral)

    assert_equal({ files: [], skipped: 0 }, result)
    assert_empty mistral.calls
  end

  def test_generates_a_test_for_a_testable_file
    mistral = FakeMistral.new(["FILE: test/services/magic_link_service_test.rb\nclass MagicLinkServiceTest < ActiveSupport::TestCase\nend\n"])

    result = with_config_override(test_generation: { enabled: true }) do
      Calvin::TestGenerator.call(files: [SERVICE], reader: FakeReader.new, mistral: mistral)
    end

    assert_equal 1, result[:files].size
    assert_equal "test/services/magic_link_service_test.rb", result[:files].first[:path]
    assert_includes result[:files].first[:content], "MagicLinkServiceTest"
  end

  def test_ignores_files_outside_testable_dirs
    model_file = { path: "app/models/user.rb", content: "class User < ApplicationRecord\nend\n" }
    mistral    = FakeMistral.new([])

    result = with_config_override(test_generation: { enabled: true }) do
      Calvin::TestGenerator.call(files: [model_file], reader: FakeReader.new, mistral: mistral)
    end

    assert_empty result[:files]
    assert_empty mistral.calls
  end

  def test_never_generates_a_test_for_a_test_file
    test_file = { path: "test/services/foo_test.rb", content: "class FooTest; end\n" }
    mistral   = FakeMistral.new([])

    result = with_config_override(test_generation: { enabled: true }) do
      Calvin::TestGenerator.call(files: [test_file], reader: FakeReader.new, mistral: mistral)
    end

    assert_empty result[:files]
  end

  # Non vale la chiamata al modello per un file che non parserebbe comunque — il gate
  # syntax lo boccerebbe subito dopo.
  def test_skips_files_that_fail_the_syntax_pre_check
    broken  = { path: "app/services/broken_service.rb", content: "class Broken\n  def call\nend\n" }
    mistral = FakeMistral.new([])

    result = with_config_override(test_generation: { enabled: true }) do
      Calvin::TestGenerator.call(files: [broken], reader: FakeReader.new, mistral: mistral)
    end

    assert_empty result[:files]
    assert_empty mistral.calls
  end

  def test_respects_the_max_files_cap
    services = (1..5).map { |i| { path: "app/services/s#{i}_service.rb", content: "# frozen_string_literal: true\n\nclass S#{i}Service\nend\n" } }
    mistral  = FakeMistral.new(Array.new(5) { |i| "FILE: test/services/s#{i}_service_test.rb\nclass T#{i} < ActiveSupport::TestCase\nend\n" })

    result = with_config_override(test_generation: { enabled: true, max_files: 2 }) do
      Calvin::TestGenerator.call(files: services, reader: FakeReader.new, mistral: mistral)
    end

    assert_equal 2, result[:files].size
    assert_equal 3, result[:skipped]
  end

  def test_testable_dirs_are_configurable_per_project
    admin_service = { path: "lib/admin/report_generator.rb", content: "# frozen_string_literal: true\n\nclass ReportGenerator\nend\n" }
    mistral       = FakeMistral.new(["FILE: test/admin/report_generator_test.rb\nclass T < ActiveSupport::TestCase\nend\n"])

    result = with_config_override(test_generation: { enabled: true, testable_dirs: ["lib/admin/"] }) do
      Calvin::TestGenerator.call(files: [admin_service], reader: FakeReader.new, mistral: mistral)
    end

    assert_equal 1, result[:files].size
  end

  # Il contesto (fixtures, test_helper) va letto per path noto, non cercato per
  # similarità: verifica che finisca davvero nel messaggio inviato al modello.
  def test_includes_fixtures_and_test_helper_read_by_known_path
    reader = FakeReader.new(
      files: {
        "test/test_helper.rb"           => "require 'minitest/autorun'",
        "test/fixtures/users.yml"       => "alice:\n  email: alice@example.com"
      },
      dirs: { "test/fixtures" => ["users.yml"] }
    )
    mistral = FakeMistral.new(["FILE: test/services/magic_link_service_test.rb\nclass T < ActiveSupport::TestCase\nend\n"])

    with_config_override(test_generation: { enabled: true }) do
      Calvin::TestGenerator.call(files: [SERVICE], reader: reader, mistral: mistral)
    end

    user_message = mistral.calls.first.last[:content]
    assert_includes user_message, "require 'minitest/autorun'"
    assert_includes user_message, "alice@example.com"
  end

  def test_a_failed_generation_is_skipped_not_raised
    mistral = FakeMistral.new([])
    def mistral.complete_messages(*) = raise "boom"

    result = with_config_override(test_generation: { enabled: true }) do
      Calvin::TestGenerator.call(files: [SERVICE], reader: FakeReader.new, mistral: mistral)
    end

    assert_empty result[:files]
  end

  def test_a_response_without_a_file_block_is_skipped
    mistral = FakeMistral.new(["Non riesco a scrivere il test."])

    result = with_config_override(test_generation: { enabled: true }) do
      Calvin::TestGenerator.call(files: [SERVICE], reader: FakeReader.new, mistral: mistral)
    end

    assert_empty result[:files]
  end
end
