# frozen_string_literal: true
# Flusso Calvin — triggerato dalla label 'calvin'.
# Pipeline dry-transaction con 6 step espliciti:
#
#   build_prompt        — ContextBuilder costruisce il prompt dal title+body dell'issue
#   retrieve_context    — ContextRetriever: query RAG su Supabase, ritorna RetrievalResult
#   react_loop          — ReActLoop: il modello esplora e implementa
#   parse_files         — estrae FILE: blocks e PR_BODY
#   validate_and_repair — Validator + RepairLoop: il codice viene eseguito prima della PR
#   commit_and_pr       — branch + commit + PR
#
# validate_and_repair è il passaggio che rende la pipeline closed-loop: i file generati
# vengono materializzati nel clone locale, passati per la ladder di gate e, se un gate è
# rosso, rimandati al modello con l'output reale dell'errore. La PR si apre solo dopo.
#
# Stack ("rails" | "flutter") determinato dalle label dell'issue.
# Default letto da CONFIG[:repo][:stacks][:default].
#
# Contratto risultato:
#   Success(Calvin::FlowResult) con:
#     files, branch, status, usage, temperature, pr_url
#     flow_meta: { explore_turns:, validation_stage:, validation_ok:, repair_attempts: }
#   Failure({ step:, error:, usage:, explore_turns: })

require "dry/transaction"
require_relative "context_builder"
require_relative "context_retriever"
require_relative "react_loop"
require_relative "file_parser"
require_relative "validator"
require_relative "repair_loop"
require_relative "commit_and_pr"

module Calvin
  class ExploreFlow
    include Dry::Transaction

    step :build_prompt
    step :retrieve_context
    step :react_loop
    step :parse_files
    step :validate_and_repair
    step :commit_and_pr

    private

    def build_prompt(issue:, stack:, github:, workspace: nil, mistral: nil)
      Calvin.banner("EXPLORE FLOW  •  issue ##{issue.number}", emoji: "🚀")
      reader = RepoReader.new(workspace: workspace, github: github)
      Calvin::LOG.info "repo source: #{reader.source}#{reader.local? ? " (#{workspace.root})" : ''}"

      prompt = ContextBuilder.build(issue, reader: reader)
      Calvin::LOG.info "prompt built  #{(prompt.bytesize / 1024.0).round(1)} KB"
      Success(issue: issue, stack: stack, github: github, workspace: workspace,
              mistral: mistral, reader: reader, prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, usage: nil, explore_turns: 0)
    end

    def retrieve_context(issue:, stack:, github:, workspace:, mistral:, reader:, prompt:)
      Calvin.section("RAG retrieve")
      retrieval = ContextRetriever.call(issue)
      kb = retrieval.rules ? (retrieval.rules.bytesize / 1024.0).round(1) : 0
      Calvin::LOG.info "rules #{kb} KB  |  #{retrieval.chunks.size} chunks"
      Success(issue: issue, stack: stack, github: github, workspace: workspace, mistral: mistral,
              reader: reader, prompt: prompt, retrieval: retrieval)
    rescue => e
      Calvin::LOG.warn "ContextRetriever failed (#{e.message}) — continuing without rules"
      empty = RetrievalResult.new(rules: nil, context: nil, chunks: [])
      Success(issue: issue, stack: stack, github: github, workspace: workspace, mistral: mistral,
              reader: reader, prompt: prompt, retrieval: empty)
    end

    def react_loop(issue:, stack:, github:, workspace:, mistral:, reader:, prompt:, retrieval:)
      loop_obj = ReActLoop.new(reader, prompt, stack: stack, retrieval: retrieval,
                                              issue_number: issue.number, mistral: mistral)
      result   = loop_obj.run

      exp_c = result[:retrieval_explore].chunks.size
      imp_c = result[:retrieval_implement].chunks.size
      Calvin::LOG.info "react_loop done  turns=#{result[:turns]}  rag_explore=#{exp_c}  rag_implement=#{imp_c}"

      Success(
        issue:                issue,
        stack:                stack,
        github:               github,
        workspace:            workspace,
        mistral:              mistral,
        content:              result[:content],
        usage:                result[:usage],
        usage_explore:        result[:usage_explore],
        temperature:          result[:temperature],
        explore_turns:        result[:turns],
        file_plan:            result[:file_plan],
        originals:            result[:originals],
        retrieval_explore:    result[:retrieval_explore],
        retrieval_implement:  result[:retrieval_implement]
      )
    rescue => e
      Failure(step: :react_loop, error: e.message, usage: nil, explore_turns: 0)
    end

    def parse_files(issue:, stack:, github:, workspace:, mistral:, content:, usage:, usage_explore:,
                    temperature:, explore_turns:, file_plan:, originals:,
                    retrieval_explore:, retrieval_implement:)
      files   = FileParser.parse(content)
      pr_body = FileParser.parse_pr_body(content)

      files = files.reject { |f| f[:path].start_with?("test/") } unless Calvin.feature?(:generate_tests)

      raise "nessun FILE block nell'output del modello" if files.empty?

      Calvin::LOG.info "parsed #{files.size} file(s)  →  #{files.map { |f| f[:path] }.join(', ')}"
      Success(
        issue:                issue,
        github:               github,
        workspace:            workspace,
        mistral:              mistral,
        files:                files,
        pr_body:              pr_body,
        usage:                usage,
        usage_explore:        usage_explore,
        temperature:          temperature,
        explore_turns:        explore_turns,
        file_plan:            file_plan,
        originals:            originals,
        retrieval_explore:    retrieval_explore,
        retrieval_implement:  retrieval_implement
      )
    rescue => e
      Failure(step: :parse_files, error: e.message, usage: usage, explore_turns: explore_turns)
    end

    # Il codice viene eseguito qui, non dopo la PR. Se resta rosso dopo i tentativi di
    # repair, il comportamento dipende da validation.open_pr_when_red:
    #   true  → la PR si apre marcata (label + errori nel body), ispezionabile a mano
    #   false → nessuna PR, l'errore torna come Failure e finisce sull'issue
    def validate_and_repair(issue:, github:, workspace:, mistral:, files:, pr_body:, usage:,
                            usage_explore:, temperature:, explore_turns:, file_plan:, originals:,
                            retrieval_explore:, retrieval_implement:)
      config = Calvin::CONFIG[:validation] || {}
      Calvin.phase_start(:validate, "level=#{config[:level] || 'static'}  #{files.size} file(s)")

      validation = Validator.call(
        files: files, workspace: workspace, github: github,
        file_plan: file_plan, originals: originals, issue: issue
      )

      repair_attempts = 0
      repair_usage    = nil

      if validation.red?
        repaired = RepairLoop.call(
          files: files, validation: validation, workspace: workspace, github: github,
          mistral: mistral, file_plan: file_plan, originals: originals, issue: issue
        )
        files           = repaired[:files]
        validation      = repaired[:validation]
        repair_attempts = repaired[:attempts]
        repair_usage    = repaired[:usage]
      end

      Calvin.phase_end(:validate, "#{validation.ok? ? 'verde' : "ROSSO su #{validation.stage}"}  repair=#{repair_attempts}")

      if validation.red? && !config.fetch(:open_pr_when_red, true)
        return Failure(step: :validate_and_repair,
                       error: "validazione rossa su #{validation.stage} dopo #{repair_attempts} repair:\n#{validation.output}",
                       usage: usage, explore_turns: explore_turns)
      end

      Success(
        issue:                issue,
        github:               github,
        files:                files,
        pr_body:              pr_body,
        usage:                usage,
        usage_explore:        usage_explore,
        temperature:          temperature,
        explore_turns:        explore_turns,
        validation:           validation,
        repair_attempts:      repair_attempts,
        repair_usage:         repair_usage,
        retrieval_explore:    retrieval_explore,
        retrieval_implement:  retrieval_implement
      )
    rescue => e
      Failure(step: :validate_and_repair, error: e.message, usage: usage, explore_turns: explore_turns)
    end

    def commit_and_pr(issue:, github:, files:, pr_body:, usage:, usage_explore:, temperature:,
                      explore_turns:, validation:, repair_attempts:, repair_usage:,
                      retrieval_explore:, retrieval_implement:)
      Calvin.phase_start(:commit, "#{files.size} file(s)")
      outcome = CommitAndPr.call(
        issue:                issue,
        github:               github,
        files:                files,
        usage:                usage,
        usage_explore:        usage_explore,
        turns:                explore_turns,
        retrieval_explore:    retrieval_explore,
        retrieval_implement:  retrieval_implement,
        description:          pr_body,
        validation:           validation,
        repair_attempts:      repair_attempts
      )
      return Failure(step: :commit_and_pr, error: outcome.failure[:error], usage: usage, explore_turns: explore_turns) if outcome.failure?

      result = outcome.value!

      # Una PR rossa va marcata: senza label è indistinguibile da una pronta al merge.
      mark_red(github, result[:pr_url], validation) if validation&.red?

      # ── Flow summary ────────────────────────────────────────────────────────
      ue = usage_explore || {}
      ui = usage || {}
      ur = repair_usage || {}
      Calvin.flow_summary([
        ["explore turns",   explore_turns],
        ["tokens explore",  "in=#{ue['prompt_tokens']} cached=#{ue['cached_tokens']} out=#{ue['completion_tokens']}"],
        ["tokens impl",     "in=#{ui['prompt_tokens']} out=#{ui['completion_tokens']}"],
        ["validation",      validation ? "#{validation.ok? ? 'verde' : "rosso/#{validation.stage}"} (repair=#{repair_attempts})" : "n/a"],
        ["tokens repair",   repair_attempts.to_i.positive? ? "in=#{ur['prompt_tokens']} out=#{ur['completion_tokens']}" : "—"],
        ["files written",   files.size],
        ["PR",              result[:pr_url]]
      ])

      Success(FlowResult.new(
        files:       result[:files],
        branch:      result[:branch],
        status:      validation&.red? ? :partial : result[:status],
        usage:       usage,
        temperature: temperature,
        pr_url:      result[:pr_url],
        flow_meta:   {
          explore_turns:    explore_turns,
          validation_ok:    validation&.ok?,
          validation_stage: validation&.stage,
          repair_attempts:  repair_attempts
        }
      ))
    rescue => e
      Failure(step: :commit_and_pr, error: e.message, usage: usage, explore_turns: explore_turns)
    end

    def mark_red(github, pr_url, validation)
      label = Calvin::CONFIG.dig(:validation, :red_label) || "calvin:red"
      number = pr_url.to_s[%r{/pull/(\d+)}, 1]
      return unless number

      github.add_label(number.to_i, label)
      Calvin::LOG.warn "PR ##{number} marcata #{label} — gate #{validation.stage} rosso"
    rescue => e
      Calvin::LOG.warn "impossibile applicare la label #{label}: #{e.message}"
    end
  end
end
