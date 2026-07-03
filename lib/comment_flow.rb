# frozen_string_literal: true
# Gestisce il flusso agent:
# prompt → Mistral → commento markdown sull'issue
#
# .run → Success(comment_url) | Failure(msg)

require "dry/monads"

module Calvin
  class CommentFlow
    include Dry::Monads[:result]

    def initialize(github, issue, prompt)
      @github = github
      @issue  = issue
      @prompt = prompt
    end

    def run
      notes = MistralClient.new.complete(@prompt)

      comment = <<~MD
        <!-- calvin-status -->
        ## 📤 Risposta Calvin

        #{notes}

        <details><summary>Prompt inviato</summary>

        ```
        #{@prompt}
        ```

        </details>
      MD

      @github.post_status(@issue, comment)
      Calvin::LOG.info "##{@issue.number} done"
      Success(:comment_posted)
    rescue StandardError => e
      Failure("CommentFlow error: #{e.message}")
    end
  end
end
