# frozen_string_literal: true
# Ritorna il prompt così com'è — il commento agent-prompt è già completo.
# Esiste come indirection point nel caso in futuro vogliamo aggiungere
# un system prompt globale o altro wrapping.

module Calvin
  class PromptBuilder
    def self.build(_issue, prompt) = prompt
  end
end
