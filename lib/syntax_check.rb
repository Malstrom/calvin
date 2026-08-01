# frozen_string_literal: true
# Calvin::SyntaxCheck — verifica sintattica Ruby condivisa.
#
# Estratto da Validator#gate_syntax perché lo stesso controllo serve anche a
# TestGenerator: non ha senso spendere una chiamata al modello per scrivere un test di un
# file che non parserebbe comunque — il gate syntax lo boccerebbe subito dopo, sprecando
# il turno di generazione.
#
# .ok?(content)       → true | false
# .error_for(content) → String | nil  (output di `ruby -c`, solo se il contenuto non è valido)

require "open3"

module Calvin
  module SyntaxCheck
    extend self

    def ok?(content)
      error_for(content).nil?
    end

    def error_for(content)
      out, status = Open3.capture2e("ruby", "-c", stdin_data: content.to_s)
      status.success? ? nil : out.strip
    end
  end
end
