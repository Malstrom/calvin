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
      prompt = ContextBuilder.build(issue)
      Calvin::LOG.info "ExploreFlow: prompt built (#{prompt.bytesize} bytes)"
      Success(issue: issue, stack: stack, github: github, prompt: prompt)
    rescue => e
      Failure(step: :build_prompt, error: e.message, usage: nil, explore_turns: 0)
    end

    def retrieve_context(issue:, stack:, github:, prompt:)
      retrieval = ContextRetriever.call(issue)
      Calvin::LOG.info "ExploreFlow: retrieval done — rules=#{retrieval.rules.nil? ? 'nil' : "#{retrieval.rules.bytesize}b"}"
      Success(issue: issue, stack: stack, github: github, prompt: prompt, retrieval: retrieval)
    rescue => e
      Calvin::LOG.warn "ExploreFlow: ContextRetriever failed (#{e.message}) — continuing without rules"
      empty = RetrievalResult.new(rules: nil, context: nil)
      Success(issue: issue, stack: stack, github: github, prompt: prompt, retrieval: empty)
    end

    def react_loop(issue:, stack:, github:, prompt:, retrieval:)
      loop = ReActLoop.new(github, prompt, stack: stack, retrieval: retrieval)
      result = loop.run
      Calvin::LOG.info "ExploreFlow: react_loop done — turns=#{result[:turns]}"
      Success(
        issue:         issue,
        stack:         stack,
        github:        github,
        content:       result[:content],
        usage:         result[:usage],
        temperature:   result[:temperature],
        explore_turns: result[:turns]
      )
    rescue => e
      Failure(step: :react_loop, error: e.message, usage: nil, explore_turns: 0)
    end

    def parse_files(issue:, stack:, github:, content:, usage:, temperature:, explore_turns:)
      parsed = FileParser.parse(content)
      Calvin::LOG.info "ExploreFlow: parsed #{parsed[:files].size} file(s)"
      Success(
        issue:         issue,
        github:        github,
        files:         parsed[:files],
        pr_body:       parsed[:pr_body],
        usage:         usage,
        temperature:   temperature,
        explore_turns: explore_turns
      )
    rescue => e
      Failure(step: :parse_files, error: e.message, usage: usage, explore_turns: explore_turns)
    end

    def commit_and_pr(issue:, github:, files:, pr_body:, usage:, temperature:, explore_turns:)
      result = CommitAndPr.call(
        issue:       issue,
        github:      github,
        files:       files,
        pr_body:     pr_body,
        usage:       usage,
        temperature: temperature
      )
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
