# frozen_string_literal: true
# Calvin::FlowResult — contratto condiviso tra tutti i flow.
#
# Campi obbligatori (presenti in ogni flow):
#   files:       Array<{ path: String, content: String }>
#   branch:      String
#   status:      Symbol  # :success | :failure | :partial
#
# Campi opzionali (nil se non applicabili al flow):
#   usage:       Hash | nil   # { "prompt_tokens" =>, "completion_tokens" =>, "total_tokens" => }
#   temperature: Float | nil
#   pr_url:      String | nil
#
# Campo meta (hash libero per campi specifici del singolo flow):
#   flow_meta:   Hash         # default {}
#
# Campi flow_meta noti:
#   explore_turns: Integer    # ExploreFlow — numero di turn ReAct
#   files_fixed:   Integer    # PrRubocopFixFlow (futuro)
#   tests_fixed:   Integer    # PrTestFixFlow (futuro)
#
# Uso:
#   result = Calvin::FlowResult.success(
#     files:     [...],
#     branch:    "auto/issue-1-123",
#     usage:     { ... },
#     pr_url:    "https://...",
#     flow_meta: { explore_turns: 12 }
#   )
#   result.flow_meta[:explore_turns]  # => 12
#   result.flow_meta[:files_fixed]    # => nil (assente, non crasha)

module Calvin
  FlowResult = Struct.new(
    :files,
    :branch,
    :status,
    :usage,
    :temperature,
    :pr_url,
    :flow_meta,
    keyword_init: true
  ) do
    def self.success(files:, branch:, pr_url: nil, usage: nil, temperature: nil, flow_meta: {})
      new(
        files:       files,
        branch:      branch,
        status:      :success,
        usage:       usage,
        temperature: temperature,
        pr_url:      pr_url,
        flow_meta:   flow_meta
      )
    end

    def self.failure(files: [], branch: "", pr_url: nil, usage: nil, temperature: nil, flow_meta: {})
      new(
        files:       files,
        branch:      branch,
        status:      :failure,
        usage:       usage,
        temperature: temperature,
        pr_url:      pr_url,
        flow_meta:   flow_meta
      )
    end

    # Accesso difensivo a flow_meta: mai KeyError, sempre nil se assente.
    def meta(key)
      flow_meta&.fetch(key, nil)
    end
  end
end
