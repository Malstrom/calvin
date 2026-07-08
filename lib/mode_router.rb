# frozen_string_literal: true
# Determina il mode di esecuzione Calvin in base alle label.
#
# Centralizza il routing — nessun if inline sulle label nei bin/.
# Le label di trigger sono lette da Calvin::CONFIG — nessun valore hardcodato.
#
# Mode correnti:
#   :explore_issue — label da routing.labels.explore (default: "calvin") su issue synca
#   :unknown       — nessuna label Calvin riconosciuta
#
# Uso:
#   mode = Calvin::ModeRouter.for_labels(labels)
#   # => :explore_issue | :unknown

module Calvin
  module ModeRouter
    LABEL_EXPLORE = (Calvin::CONFIG.dig(:routing, :labels, :explore) || "calvin").freeze

    def self.for_labels(labels)
      return :explore_issue if labels.include?(LABEL_EXPLORE)

      :unknown
    end
  end
end
