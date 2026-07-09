# frozen_string_literal: true
# Costruisce il body Markdown della PR.
# Estratto da commit_and_pr.rb — singola responsabilità.
#
# Struttura body:
#   1. Description prodotta da Codestral (include What/Decisions/Rules applied/Rule candidates)
#   2. Token usage (se disponibile)
#   3. Footer: "Implemented by Calvin via Codestral <version>" + "Closes #N"
#
# Uso:
#   Calvin::PrBodyBuilder.build(issue:, usage:, description:)          → String (PR body)
#   Calvin::PrBodyBuilder.review_comment(usage:, review_text:)         → String (review comment)

module Calvin
  module PrBodyBuilder
    def self.build(issue:, usage:, description: nil)
      model_version = Calvin::MODEL.to_s

      description_section = description.to_s.strip.empty? \
        ? "_No description provided._"
        : description.to_s.strip

      parts = []
      parts << description_section
      parts << token_table(usage) if usage
      parts << "---"
      parts << "Implemented by Calvin via Codestral (`#{model_version}`)."
      parts << "Closes ##{issue.number}"

      parts.join("\n\n")
    end

    # Body del commento di review postato da PrReviewFlow
    def self.review_comment(usage:, review_text: nil)
      model_version = Calvin::MODEL.to_s

      parts = []
      parts << review_text.to_s.strip unless review_text.to_s.strip.empty?
      parts << token_table(usage) if usage
      parts << "---"
      parts << "Reviewed by Calvin via Codestral (`#{model_version}`)."

      parts.join("\n\n")
    end

    # ── private ────────────────────────────────────────────────────────────────

    def self.token_table(usage)
      pt = usage["prompt_tokens"]     || 0
      ct = usage["completion_tokens"] || 0
      tt = usage["total_tokens"]      || 0
      <<~TABLE.strip
        ### 📊 Token usage
        | prompt | completion | total |
        |--------|------------|-------|
        | #{pt} | #{ct} | #{tt} |
      TABLE
    end
    private_class_method :token_table
  end
end
