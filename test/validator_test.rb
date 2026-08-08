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

  # La regola "niente validates nei model" è di synca, non di Rails: ora la dichiara il
  # progetto in .calvin/project.yml e il Validator la applica senza conoscerla.
  MODEL_VALIDATES_RULE = [{
    paths:   "app/models/**",
    pattern: '^\s*validates?\s',
    message: "i model del progetto sono strutture dati"
  }].freeze

  def test_rejects_forbidden_pattern_declared_by_the_project
    files = [{ path: "app/models/user.rb", content: "class User < ApplicationRecord\n  validates :email, presence: true\nend\n" }]

    result = validate(files, profile: profile_with(MODEL_VALIDATES_RULE))

    refute result.ok?
    assert_equal :structural, result.stage
    assert_includes result.output, "strutture dati"
  end

  # Il contraltare, ed è il punto dello step: lo stesso file su un progetto che non dichiara
  # quella regola passa. Prima veniva bocciato comunque, perché la regola era nel motore.
  def test_accepts_validates_when_the_project_does_not_forbid_it
    files = [{ path: "app/models/user.rb", content: "class User < ApplicationRecord\n  validates :email, presence: true\nend\n" }]

    result = validate(files)

    assert result.ok?, "atteso verde su un progetto senza forbidden_patterns, ottenuto #{result.stage}: #{result.output}"
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
  def validate(files, originals: {}, file_plan: nil, profile: nil)
    Calvin::Validator.call(files: files, workspace: nil, github: nil,
                           originals: originals, file_plan: file_plan, profile: profile)
  end

  # Profilo con una regola dichiarata dal progetto, come se venisse da .calvin/project.yml.
  def profile_with(forbidden_patterns)
    Calvin::ProjectProfile.new(data: { forbidden_patterns: forbidden_patterns })
  end
end
