# frozen_string_literal: true
# Costruisce il body Markdown della PR.
# Estratto da commit_and_pr.rb — singola responsabilità.
#
# Uso:
#   Calvin::PrBodyBuilder.build(issue:, usage:, description:) → String

module Calvin
  module PrBodyBuilder
    def self.build(issue:, usage:, description: nil)
      token_section = if usage
        pt = usage["prompt_tokens"]     || 0
        ct = usage["completion_tokens"] || 0
        tt = usage["total_tokens"]      || 0
        <<~TABLE
          ### 📊 Token usage
          | prompt | completion | total |
          |--------|------------|-------|
          | #{pt} | #{ct} | #{tt} |
        TABLE
      else
        ""
      end

      description_section = description || "_No description provided by agent._"

      <<~BODY
        Closes ##{issue.number}

        Implemented by Calvin via Codestral.

        #{description_section}

        #{token_section}
      BODY
    end
  end
end
