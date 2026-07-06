# frozen_string_literal: true
# Determina il mode di esecuzione Calvin in base alle label dell'issue.
#
# Centralizza il routing — bin/calvin.rb non contiene più if inline sulle label.
# Le label di trigger sono lette da Calvin::CONFIG — nessun valore hardcodato.
#
# Mode correnti:
#   :explore_issue   — label da config routing.labels.explore (default: "calvin")
#   :unknown         — nessuna label Calvin riconosciuta
#
# Mode futuri (issue #18):
#   :pr_rubocop_fix  — label "calvin-rubocop" su PR synca (PrRubocopFixFlow)
#   :pr_test_fix     — label "calvin-test-fix" su PR synca (PrTestFixFlow)
#
# Uso:
#   mode = Calvin::ModeRouter.for_labels(labels)
#   # => :explore_issue | :unknown

module Calvin
  module ModeRouter
    # Lette da CONFIG — nessun valore hardcodato.
    LABEL_EXPLORE = (Calvin::CONFIG.dig(:routing, :labels, :explore) || "calvin").freeze

    def self.for_labels(labels)
      return :explore_issue if labels.include?(LABEL_EXPLORE)

      :unknown
    end
  end
end
