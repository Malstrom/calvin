# frozen_string_literal: true

require_relative "test_helper"

class RubocopRunnerTest < Minitest::Test
  # Un'offesa che rubocop sa correggere da sola non deve bloccare il flow: il post-step
  # RubocopAutocorrect la sistema gratis. Mandarla al repair loop sarebbe spendere token
  # del modello per il lavoro di un formatter.
  def test_correctable_offenses_do_not_block
    # Offese presenti e tutte correggibili: manca frozen_string_literal, c'è
    # un'assegnazione ridondante e whitespace di troppo.
    messy = <<~RB
      # Documented on purpose: Style/Documentation is not correctable and would
      # blur what this test is about.
      class Messy
        def call
          x = 1
          x
        end
      end
    RB
    files = [{ path: "app/services/messy.rb", content: messy }]

    result = Calvin::RubocopRunner.remaining_offenses(files: files)

    refute_nil result
    assert_equal 0, result[:count], "atteso zero blocking, ottenuto: #{result[:output]}"
  end

  def test_reports_non_correctable_offenses_with_project_paths
    # Metrics/ParameterLists non è correggibile automaticamente.
    long_params = (1..12).map { |i| "a#{i}" }.join(", ")
    files = [{ path: "app/services/wide.rb", content: <<~RB }]
      # frozen_string_literal: true

      class Wide
        def call(#{long_params})
          true
        end
      end
    RB

    result = Calvin::RubocopRunner.remaining_offenses(files: files)

    refute_nil result
    assert_operator result[:count], :>, 0
    assert_includes result[:paths], "app/services/wide.rb"
    assert_includes result[:output], "app/services/wide.rb:"
    refute_includes result[:output], "/tmp/", "i path della tmpdir non vanno esposti al modello"
  end

  def test_returns_nil_without_ruby_files
    assert_nil Calvin::RubocopRunner.remaining_offenses(files: [{ path: "config/locales/it.yml", content: "it:\n" }])
  end

  def test_run_returns_noop_without_ruby_files
    result = Calvin::RubocopRunner.run(files: [{ path: "a.yml", content: "x: 1\n" }], github: nil)

    assert_equal :noop, result[:status]
  end
end
