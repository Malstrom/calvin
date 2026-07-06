# frozen_string_literal: true
# Determina il mode di esecuzione Calvin in base alle label dell'issue.
#
# Centralizza il routing — bin/calvin.rb non contiene più if inline sulle label.
#
# Mode correnti:
#   :explore_issue   — label "calvin" su issue synca (ExploreFlow)
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
    LABEL_EXPLORE = "calvin"

    def self.for_labels(labels)
      return :explore_issue if labels.include?(LABEL_EXPLORE)

      :unknown
    end
  end
end
