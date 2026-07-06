# frozen_string_literal: true
# Determina il mode di esecuzione Calvin in base alle label.
#
# Centralizza il routing — nessun if inline sulle label nei bin/.
# Le label di trigger sono lette da Calvin::CONFIG — nessun valore hardcodato.
#
# Mode correnti:
#   :explore_issue   — label da routing.labels.explore (default: "calvin") su issue synca
#   :pr_review       — label da routing.labels.pr_review (default: "calvin-fix") su PR synca
#   :unknown         — nessuna label Calvin riconosciuta
#
# Uso:
#   mode = Calvin::ModeRouter.for_labels(labels)
#   # => :explore_issue | :pr_review | :unknown

module Calvin
  module ModeRouter
    LABEL_EXPLORE   = (Calvin::CONFIG.dig(:routing, :labels, :explore)   || "calvin").freeze
    LABEL_PR_REVIEW = (Calvin::CONFIG.dig(:routing, :labels, :pr_review) || "calvin-fix").freeze

    def self.for_labels(labels)
      return :explore_issue if labels.include?(LABEL_EXPLORE)
      return :pr_review     if labels.include?(LABEL_PR_REVIEW)

      :unknown
    end
  end
end
