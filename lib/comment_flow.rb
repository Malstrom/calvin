# frozen_string_literal: true
# Deprecato — sostituito da ImplementFlow.
# Mantenuto per compatibilità con eventuali riferimenti esterni.
# TODO: rimuovere nella prossima pulizia.

module Calvin
  class CommentFlow
    def initialize(github, issue, prompt)
      @flow = ImplementFlow.new(github, issue, prompt)
    end

    def run
      @flow.run
    end
  end
end
