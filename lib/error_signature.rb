# frozen_string_literal: true
# Calvin::ErrorSignature — normalizza l'output di un gate in una firma aggregabile.
#
# È il pezzo su cui poggia l'intero meccanismo di apprendimento: due run che sbagliano la
# stessa cosa devono produrre la stessa stringa, altrimenti non c'è nulla da contare.
# Path, numeri di riga, nomi di classe specifici e timestamp vanno via; resta la classe
# dell'errore.
#
# Esempi:
#   syntax       "app/services/x.rb:3: syntax error, unexpected end"  → "syntax/unexpected_end"
#   rubocop      "app/x.rb:1:1: Style/Documentation: Missing…"        → "rubocop/Style/Documentation"
#   structural   "app/models/user.rb: contiene `validates`…"          → "structural/validates_in_model"
#   zeitwerk     "expected file … to define constant Foo"             → "zeitwerk/constant_mismatch"
#   migrate      "PG::UndefinedColumn: ERROR: column … does not exist" → "migrate/PG::UndefinedColumn"
#   focused_test "NoMethodError: undefined method `foo' for nil"      → "focused_test/NoMethodError"
#
# .call(gate:, output:) → String
# .scope_for(path)      → String | nil   (layer derivato dal path, per raggruppare per strato)

module Calvin
  module ErrorSignature
    extend self

    UNKNOWN = "unknown"

    # I check strutturali hanno messaggi scritti da noi: il match è sul frammento stabile.
    STRUCTURAL_PATTERNS = {
      "marker di elisione"                 => "elision_marker",
      "definizioni presenti nell'originale" => "lost_definitions",
      "possibile perdita di codice"        => "excessive_shrink",
      "fuori dal piano"                    => "file_outside_plan",
      "nessun FILE block prodotto"         => "planned_file_missing",
      "non verrebbe eseguita"              => "migration_timestamp_too_low",
      "senza timestamp a 14 cifre"         => "migration_bad_name",
      "non esiste e non è stato generato"  => "route_without_controller",
      "strutture dati"                     => "validates_in_model"
    }.freeze

    # Layer del progetto, derivato dal path. Serve a rispondere a "in quale strato
    # Calvin sbaglia di più", che è la domanda operativa.
    SCOPE_BY_PREFIX = {
      "app/controllers/" => "controller",
      "app/services/"    => "service",
      "app/models/"      => "model",
      "app/jobs/"        => "job",
      "app/serializers/" => "serializer",
      "app/contracts/"   => "contract",
      "app/mailers/"     => "mailer",
      "app/queries/"     => "query",
      "app/policies/"    => "policy",
      "db/migrate/"      => "migration",
      "config/locales/"  => "locale",
      "config/"          => "config",
      "test/"            => "test"
    }.freeze

    def call(gate:, output:)
      text = output.to_s
      body = case gate.to_s
      when "syntax"       then syntax_signature(text)
      when "rubocop"      then rubocop_signature(text)
      when "structural"   then structural_signature(text)
      when "zeitwerk"     then zeitwerk_signature(text)
      else exception_signature(text)
      end

      "#{gate}/#{body || UNKNOWN}"
    end

    def scope_for(path)
      p = path.to_s
      SCOPE_BY_PREFIX.each { |prefix, scope| return scope if p.start_with?(prefix) }
      nil
    end

    private

    # "syntax error, unexpected end, expecting …" → unexpected_end
    def syntax_signature(text)
      return "unexpected_#{Regexp.last_match(1)}" if text =~ /unexpected ([a-z_']+)/i

      "error" if text.include?("syntax error")
    end

    # Il nome del cop è già una firma perfetta.
    def rubocop_signature(text)
      text[%r{\b([A-Z]\w+/[A-Z]\w+)\b}, 1]
    end

    def structural_signature(text)
      STRUCTURAL_PATTERNS.each { |fragment, name| return name if text.include?(fragment) }
      nil
    end

    def zeitwerk_signature(text)
      return "constant_mismatch" if text.include?("to define constant")
      return "unexpected_file"   if text.include?("expected file")

      nil
    end

    # Prima classe di eccezione Ruby nell'output (test, migrate, boot).
    def exception_signature(text)
      text[/\b([A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*(?:Error|Exception|Invalid|NotFound))\b/, 1] ||
        text[/\b(PG::[A-Za-z]+)\b/, 1] ||
        (text.include?("Failure") ? "test_failure" : nil)
    end
  end
end
