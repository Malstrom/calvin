# frozen_string_literal: true
# Flusso Calvin — triggerato dalla label 'calvin'.
# Pipeline dry-transaction con 5 step espliciti:
#
#   build_prompt      — ContextBuilder costruisce il prompt dal title+body dell'issue
#   retrieve_context  — ContextRetriever: query RAG su Supabase, ritorna RetrievalResult
#   react_loop        — ReActLoop: il modello esplora e implementa
#   parse_files       — estrae FILE: blocks e PR_BODY
#   commit_and_pr     — branch + commit + PR
#
# Stack ("rails" | "flutter") determinato dalle label dell'issue.
# Default letto da CONFIG[:repo][:stacks][:default].
#
# Contratto risultato:
#   Success(Calvin::FlowResult) con:
#     files, branch, status, usage, temperature, pr_url
#     flow_meta: { explore_turns: Integer }
#   Failure({ step:, error:, usage:, explore_turns: })

require "dry/transaction"
require_relative "context_builder"
require_relative "context_retriever"
require_relative "react_loop"
require_relative "file_parser"
require_relative "commit_and_pr"

module Calvin
  class ExploreFlow
    include Dry::Transaction

    step :build_prompt
    step :retrieve_context
    step :react_loop
    step :parse_files
    step :commit_and_pr

    private

    def build_prompt(issue:, stack:, github:)
      Calvin.banner("EXPLORE FLOW  •  issue ##{issue.number}", emoji: "🚀")
      prompt = ContextBuilder.build(issue)
      Calvin::LOG.info "prompt built  #{(prompt.bytesize / 1024.0).round(1)} KB"
      Success(issue: issue, stack: stack, github: github, prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, usage: nil, explore_turns: 0)
    end

    def retrieve_context(issue:, stack:, github:, prompt:)
      Calvin.section("RAG retrieve")
      retrieval = ContextRetriever.call(issue)
      kb = retrieval.rules ? (retrieval.rules.bytesize / 1024.0).round(1) : 0
      Calvin::LOG.info "rules #{kb} KB  |  #{retrieval.chunks.size} chunks"
      Success(issue: issue, stack: stack, github: github, prompt: prompt, retrieval: retrieval)
    rescue => e
      Calvin::LOG.warn "ContextRetriever failed (#{e.message}) — continuing without rules"
      empty = RetrievalResult.new(rules: nil, context: nil, chunks: [])
      Success(issue: issue, stack: stack, github: github, prompt: prompt, retrieval: empty)
    end

    def react_loop(issue:, stack:, github:, prompt:, retrieval:)
      loop_obj = ReActLoop.new(github, prompt, stack: stack, retrieval: retrieval, issue_number: issue.number)
      result   = loop_obj.run

      exp_c = result[:retrieval_explore].chunks.size
      imp_c = result[:retrieval_implement].chunks.size
      Calvin.done("react_loop  turns=#{result[:turns]}  rag_explore=#{exp_c}  rag_implement=#{imp_c}")

      Success(
        issue:                issue,
        stack:                stack,
        github:               github,
        content:              result[:content],
        usage:                result[:usage],
        usage_explore:        result[:usage_explore],
        temperature:          result[:temperature],
        explore_turns:        result[:turns],
        retrieval_explore:    result[:retrieval_explore],
        retrieval_implement:  result[:retrieval_implement]
      )
    rescue => e
      Failure(step: :react_loop, error: e.message, usage: nil, explore_turns: 0)
    end

    def parse_files(issue:, stack:, github:, content:, usage:, usage_explore:, temperature:, explore_turns:, retrieval_explore:, retrieval_implement:)
      files   = FileParser.parse(content)
      pr_body = FileParser.parse_pr_body(content)
      Calvin::LOG.info "parsed #{files.size} file(s)  →  #{files.map { |f| f[:path] }.join(', ')}"
      Success(
        issue:                issue,
        github:               github,
        files:                files,
        pr_body:              pr_body,
        usage:                usage,
        usage_explore:        usage_explore,
        temperature:          temperature,
        explore_turns:        explore_turns,
        retrieval_explore:    retrieval_explore,
        retrieval_implement:  retrieval_implement
      )
    rescue => e
      Failure(step: :parse_files, error: e.message, usage: usage, explore_turns: explore_turns)
    end

    def commit_and_pr(issue:, github:, files:, pr_body:, usage:, usage_explore:, temperature:, explore_turns:, retrieval_explore:, retrieval_implement:)
      Calvin.section("commit + PR")
      outcome = CommitAndPr.call(
        issue:                issue,
        github:               github,
        files:                files,
        usage:                usage,
        usage_explore:        usage_explore,
        turns:                explore_turns,
        retrieval_explore:    retrieval_explore,
        retrieval_implement:  retrieval_implement,
        description:          pr_body
      )
      return Failure(step: :commit_and_pr, error: outcome.failure[:error], usage: usage, explore_turns: explore_turns) if outcome.failure?

      result = outcome.value!
      Calvin.done("PR aperta → #{result[:pr_url]}")
      Success(FlowResult.new(
        files:       result[:files],
        branch:      result[:branch],
        status:      result[:status],
        usage:       usage,
        temperature: temperature,
        pr_url:      result[:pr_url],
        flow_meta:   { explore_turns: explore_turns }
      ))
    rescue => e
      Failure(step: :commit_and_pr, error: e.message, usage: usage, explore_turns: explore_turns)
    end
  end
end
