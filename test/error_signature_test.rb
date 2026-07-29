# frozen_string_literal: true

require_relative "test_helper"

# La firma è il fondamento del meccanismo di apprendimento: se due run che sbagliano la
# stessa cosa producono firme diverse, non c'è nulla da aggregare. Questi test verificano
# proprio la stabilità rispetto a path, righe e nomi specifici.
class ErrorSignatureTest < Minitest::Test
  def test_same_error_in_different_files_yields_same_signature
    a = sig(:syntax, "app/services/alpha.rb:3: syntax error, unexpected end")
    b = sig(:syntax, "app/models/beta.rb:41: syntax error, unexpected end")

    assert_equal a, b
    assert_equal "syntax/unexpected_end", a
  end

  def test_rubocop_signature_is_the_cop_name
    output = "app/services/x.rb:1:1: Style/Documentation: Missing top-level documentation comment for `class X`."

    assert_equal "rubocop/Style/Documentation", sig(:rubocop, output)
  end

  def test_structural_signatures_map_to_stable_names
    cases = {
      "app/models/user.rb: marker di elisione «rest of file» nel contenuto — il file sarebbe salvato incompleto" => "structural/elision_marker",
      "app/models/user.rb: definizioni presenti nell'originale e assenti nell'output: full_name"                 => "structural/lost_definitions",
      "app/models/big.rb: da 40 a 3 righe (-92%) — possibile perdita di codice esistente"                        => "structural/excessive_shrink",
      "app/services/x.rb: FILE block fuori dal piano (non è in modify né in create)"                             => "structural/file_outside_plan",
      "app/services/y.rb: dichiarato nel piano ma nessun FILE block prodotto"                                    => "structural/planned_file_missing",
      "db/migrate/20200101000000_x.rb: timestamp 20200101000000 <= ultima migration esistente — non verrebbe eseguita" => "structural/migration_timestamp_too_low",
      "route `post auth/x` punta a a#b ma app/controllers/a_controller.rb non esiste e non è stato generato"      => "structural/route_without_controller",
      "app/models/user.rb: contiene `validates`/`validate` — i model del progetto sono strutture dati"            => "structural/validates_in_model"
    }

    cases.each do |output, expected|
      assert_equal expected, sig(:structural, output), "output: #{output[0, 60]}"
    end
  end

  def test_zeitwerk_constant_mismatch
    output = "expected file app/services/foo.rb to define constant Foo, but didn't"

    assert_equal "zeitwerk/constant_mismatch", sig(:zeitwerk, output)
  end

  def test_migrate_signature_is_the_pg_error_class
    assert_equal "migrate/PG::UndefinedColumn",
                 sig(:migrate, "PG::UndefinedColumn: ERROR:  column \"foo\" does not exist")
  end

  def test_test_signature_is_the_exception_class
    assert_equal "focused_test/NoMethodError",
                 sig(:focused_test, "NoMethodError: undefined method `foo' for nil\n  test/services/x_test.rb:12")
  end

  def test_unknown_output_still_yields_a_usable_signature
    assert_equal "focused_test/unknown", sig(:focused_test, "qualcosa di completamente inatteso")
  end

  def test_scope_from_path
    assert_equal "controller", Calvin::ErrorSignature.scope_for("app/controllers/api/v1/x_controller.rb")
    assert_equal "service",    Calvin::ErrorSignature.scope_for("app/services/x_service.rb")
    assert_equal "migration",  Calvin::ErrorSignature.scope_for("db/migrate/20260101000000_x.rb")
    assert_equal "locale",     Calvin::ErrorSignature.scope_for("config/locales/it.yml")
    assert_equal "config",     Calvin::ErrorSignature.scope_for("config/routes.rb")
    assert_nil Calvin::ErrorSignature.scope_for("README.md")
    assert_nil Calvin::ErrorSignature.scope_for(nil)
  end

  # Il prefisso più specifico deve vincere: config/locales/ non è config/.
  def test_most_specific_prefix_wins
    assert_equal "locale", Calvin::ErrorSignature.scope_for("config/locales/en.yml")
  end

  private

  def sig(gate, output) = Calvin::ErrorSignature.call(gate: gate, output: output)
end
