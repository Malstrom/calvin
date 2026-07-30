# frozen_string_literal: true

require_relative "test_helper"

# Il Validator è la rete che sostituisce le richieste in prosa dei prompt.
# Questi test verificano che i casi che prima arrivavano committati vengano fermati.
class ValidatorTest < Minitest::Test
  def setup
    ENV["CALVIN_VALIDATION_LEVEL"] = "static"
  end

  def teardown
    ENV.delete("CALVIN_VALIDATION_LEVEL")
  end

  # ── syntax ────────────────────────────────────────────────────────────────────

  def test_rejects_syntax_error
    files = [{ path: "app/services/broken.rb", content: "class Broken\n  def call\nend\n" }]

    result = validate(files)

    refute result.ok?
    assert_equal :syntax, result.stage
    assert_includes result.failed_paths, "app/services/broken.rb"
  end

  def test_accepts_valid_syntax
    result = validate([{ path: "app/services/ok.rb", content: "class Ok\n  def call = true\nend\n" }])

    assert result.ok?, "attese zero offese, ottenuto #{result.stage}: #{result.output}"
  end

  # ── diff-guard ────────────────────────────────────────────────────────────────

  # Il caso contro cui implement_system.md combatte con 15 righe di prompt.
  def test_rejects_ellipsis_marker
    files = [{ path: "app/models/user.rb", content: <<~RB }]
      class User < ApplicationRecord
        # ... rest of file unchanged
      end
    RB

    result = validate(files, originals: { "app/models/user.rb" => "class User < ApplicationRecord\nend\n" })

    refute result.ok?
    assert_equal :structural, result.stage
    assert_includes result.output, "marker di elisione"
  end

  def test_rejects_file_that_lost_definitions
    original = <<~'RB'
      class User < ApplicationRecord
        has_many :sessions

        def full_name
          "#{first_name} #{last_name}"
        end

        def admin?
          role == "admin"
        end
      end
    RB

    # Il modello riscrive il file tenendo solo il metodo che gli interessava.
    rewritten = <<~RB
      class User < ApplicationRecord
        has_many :sessions

        def admin?
          role == "admin"
        end
      end
    RB

    result = validate([{ path: "app/models/user.rb", content: rewritten }],
                      originals: { "app/models/user.rb" => original })

    refute result.ok?
    assert_equal :structural, result.stage
    assert_includes result.output, "full_name"
  end

  def test_accepts_file_that_only_adds_lines
    original = "class User < ApplicationRecord\n  has_many :sessions\nend\n"
    grown    = "class User < ApplicationRecord\n  has_many :sessions\n  has_many :tokens\nend\n"

    result = validate([{ path: "app/models/user.rb", content: grown }],
                      originals: { "app/models/user.rb" => original })

    assert result.ok?, "#{result.stage}: #{result.output}"
  end

  def test_rejects_excessive_shrink
    original = (1..40).map { |i| "  # line #{i}\n" }.join
    original = "class Big\n#{original}end\n"
    shrunk   = "class Big\n  # line 1\nend\n"

    result = validate([{ path: "app/models/big.rb", content: shrunk }],
                      originals: { "app/models/big.rb" => original })

    refute result.ok?
    assert_includes result.output, "possibile perdita di codice esistente"
  end

  # ── gate strutturali ──────────────────────────────────────────────────────────

  def test_rejects_validates_in_model
    files = [{ path: "app/models/user.rb", content: "class User < ApplicationRecord\n  validates :email, presence: true\nend\n" }]

    result = validate(files)

    refute result.ok?
    assert_includes result.output, "strutture dati"
  end

  def test_rejects_route_without_controller
    routes = <<~RB
      Rails.application.routes.draw do
        post "auth/magic_link", to: "api/v1/auth/magic_links#create"
      end
    RB

    result = validate([{ path: "config/routes.rb", content: routes }],
                      originals: { "config/routes.rb" => "Rails.application.routes.draw do\nend\n" })

    refute result.ok?
    assert_includes result.output, "app/controllers/api/v1/auth/magic_links_controller.rb"
  end

  def test_accepts_route_whose_controller_is_generated_in_the_same_run
    routes = <<~RB
      Rails.application.routes.draw do
        post "auth/magic_link", to: "api/v1/auth/magic_links#create"
      end
    RB
    controller = "class Api::V1::Auth::MagicLinksController < ApplicationController\nend\n"

    result = validate(
      [
        { path: "config/routes.rb", content: routes },
        { path: "app/controllers/api/v1/auth/magic_links_controller.rb", content: controller }
      ],
      originals: { "config/routes.rb" => "Rails.application.routes.draw do\nend\n" }
    )

    assert result.ok?, "#{result.stage}: #{result.output}"
  end

  def test_rejects_migration_with_timestamp_below_floor
    files = [{ path: "db/migrate/20200101000000_add_foo.rb", content: "class AddFoo < ActiveRecord::Migration[7.1]\nend\n" }]

    with_workspace(files: { "db/migrate/20260101000000_existing.rb" => "class Existing; end\n" }) do |ws|
      result = Calvin::Validator.call(files: files, workspace: ws, file_plan: nil)

      refute result.ok?
      assert_includes result.output, "non verrebbe eseguita"
    end
  end

  def test_accepts_migration_above_floor
    files = [{ path: "db/migrate/20260101000001_add_foo.rb", content: "class AddFoo < ActiveRecord::Migration[7.1]\nend\n" }]

    with_workspace(files: { "db/migrate/20260101000000_existing.rb" => "class Existing; end\n" }) do |ws|
      result = Calvin::Validator.call(files: files, workspace: ws, file_plan: nil)

      assert result.ok?, "#{result.stage}: #{result.output}"
    end
  end

  # ── file_plan vs output ───────────────────────────────────────────────────────

  def test_rejects_file_outside_the_plan
    files = [{ path: "app/services/surprise.rb", content: "class Surprise; end\n" }]
    plan  = { modify: [], create: ["app/services/expected.rb"], reference: [] }

    result = validate(files, file_plan: plan)

    refute result.ok?
    assert_includes result.output, "fuori dal piano"
    assert_includes result.output, "nessun FILE block prodotto"
  end

  def test_accepts_output_aligned_with_plan
    files = [{ path: "app/services/expected.rb", content: "class Expected; end\n" }]
    plan  = { modify: [], create: ["app/services/expected.rb"], reference: [] }

    result = validate(files, file_plan: plan)

    assert result.ok?, "#{result.stage}: #{result.output}"
  end

  # ── comportamento generale ────────────────────────────────────────────────────

  def test_skips_when_no_files
    result = Calvin::Validator.call(files: [], workspace: nil)

    assert result.ok?
    assert_equal :skipped, result.stage
  end

  # ── ordine autocorrect/valutazione ─────────────────────────────────────────────
  #
  # Regressione da un run reale: il gate rubocop scartava il risultato dell'autocorrect
  # e valutava solo cosa restava rosso. La PR nasceva con le offese correggibili ancora
  # presenti, e un commit separato le sistemava DOPO che la PR era già aperta — il repair
  # loop, nel frattempo, sprecava tentativi su file che avevano anche offese banali mai
  # ripulite. L'autocorrect va applicato PRIMA di decidere cosa è rosso.

  # Documentato apposta: Style/Documentation non è correggibile e offuscherebbe il test
  # (farebbe restare rosso il gate anche quando l'unica cosa che vogliamo è "solo offese
  # correggibili").
  MESSY_SERVICE = <<~RB
    # Documented on purpose: Style/Documentation is not correctable.
    class Messy
      def call
        x = 1
        x
      end
    end
  RB

  def test_correctable_offense_is_fixed_even_when_gate_stays_red_for_another_reason
    # redundant assignment (correggibile) + troppi parametri (non correggibile, resta rosso)
    long_params = (1..12).map { |i| "a#{i}" }.join(", ")
    original = <<~RB
      # Documented on purpose: Style/Documentation is not correctable.
      class Wide
        def call(#{long_params})
          x = 1
          x
        end
      end
    RB
    files = [{ path: "app/services/wide.rb", content: original }]

    result = Calvin::Validator.call(files: files, workspace: nil, github: FakeReader.new)

    refute result.ok?
    assert_equal :rubocop, result.stage
    assert_includes result.output, "app/services/wide.rb"

    # files è lo stesso array passato: la mutazione in place deve essere visibile qui.
    # L'assegnazione ridondante correggibile deve sparire anche se il gate resta rosso
    # per Metrics/ParameterLists (non correggibile).
    refute_equal original, files.first[:content],
                 "l'offesa correggibile doveva essere sistemata anche se il gate resta rosso"
    refute_includes files.first[:content], "x = 1\n    x\n"
  end

  def test_only_correctable_offenses_turn_the_gate_green
    files = [{ path: "app/services/messy.rb", content: MESSY_SERVICE }]

    result = Calvin::Validator.call(files: files, workspace: nil, github: FakeReader.new)

    assert result.ok?, "#{result.stage}: #{result.output}"
    refute_equal MESSY_SERVICE, files.first[:content], "l'assegnazione ridondante andava rimossa"
  end

  def test_rubocop_corrections_are_written_back_to_the_workspace
    with_workspace(files: {}) do |ws|
      files = [{ path: "app/services/messy.rb", content: MESSY_SERVICE }]

      result = Calvin::Validator.call(files: files, workspace: ws, github: nil)

      assert result.ok?, "#{result.stage}: #{result.output}"
      refute_equal MESSY_SERVICE, ws.read("app/services/messy.rb")
    end
  end

  def test_full_only_gates_are_skipped_at_static_level
    # Senza workspace i gate shell non sono eseguibili: a livello static non devono
    # nemmeno essere tentati, quindi il risultato resta verde.
    result = validate([{ path: "app/services/ok.rb", content: "class Ok; end\n" }])

    assert result.ok?
    assert_equal :all, result.stage
  end

  private

  # Valida senza workspace (solo gate statici) — rubocop viene saltato perché senza
  # github non c'è config del repo target da applicare.
  def validate(files, originals: {}, file_plan: nil)
    Calvin::Validator.call(files: files, workspace: nil, github: nil,
                           originals: originals, file_plan: file_plan)
  end
end
