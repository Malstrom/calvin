# frozen_string_literal: true
# Costruisce il body Markdown della PR.
# Estratto da commit_and_pr.rb — singola responsabilità.
#
# Struttura body:
#   1. Description prodotta da Codestral (o placeholder)
#   2. Token usage (se disponibile)
#   3. Footer: "Implemented by Calvin via Codestral <version>" + "Closes #N"
#
# Uso:
#   Calvin::PrBodyBuilder.build(issue:, usage:, description:) → String

module Calvin
  module PrBodyBuilder
    def self.build(issue:, usage:, description: nil)
      model_version = Calvin::MODEL.to_s

      description_section = description.to_s.strip.empty? \
        ? "_No description provided._"
        : description.to_s.strip

      token_section = if usage
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

      parts = []
      parts << description_section
      parts << token_section if token_section
      parts << "---"
      parts << "Implemented by Calvin via Codestral (`#{model_version}`)."
      parts << "Closes ##{issue.number}"

      parts.join("\n\n")
    end
  end
end
