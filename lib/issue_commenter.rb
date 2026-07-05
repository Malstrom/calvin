# frozen_string_literal: true
# Posta il commento di stato Calvin su un issue GitHub.
# Estratto da implement_flow.rb — singola responsabilità.
#
# Uso:
#   Calvin::IssueCommenter.post(issue:, content:, usage:, github:)

module Calvin
  module IssueCommenter
    def self.post(issue:, content:, usage:, github:)
      token_report = if usage
        pt = usage["prompt_tokens"]     || 0
        ct = usage["completion_tokens"] || 0
        tt = usage["total_tokens"]      || 0
        "| prompt | completion | total |\n|--------|------------|-------|\n| #{pt} | #{ct} | #{tt} |"
      else
        "_token data unavailable_"
      end

      github.post_status(issue, <<~MD)
        <!-- calvin-status -->
        ## 📤 Calvin — Implementation Plan

        #{content}

        ---
        ### 📊 Token usage
        #{token_report}
      MD
    end
  end
end
