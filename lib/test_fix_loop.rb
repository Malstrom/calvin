# frozen_string_literal: true
# Orchestratore del test fix loop.
#
# Dopo che Calvin ha committato i file sul branch, questo loop:
#  1. Esegue la suite di test (TestRunner)
#  2. Se tutti passano → esce con passed: true
#  3. Se falliscono → costruisce prompt minimale (TestFixPromptBuilder)
#     → chiama Codestral con system message → parsa i FILE: blocks → committa il fix
#  4. Ripete fino a max_attempts
#  5. In ogni caso ritorna { passed:, fix_attempts:, last_output: }
#
# La PR viene sempre aperta dall'orchestratore (ExploreFlow) —
# questo oggetto non sa nulla di PR o issue, solo di test e commit.
#
# Uso:
#   result = Calvin::TestFixLoop.new(
#     branch:         "auto/issue-42-123",
#     rails_root:     "/path/to/synca/backend/api",
#     github:         github_client,
#     mistral:        mistral_client,
#     max_attempts:   Calvin::CONFIG.dig(:test_fix, :max_attempts) || 2
#   ).run

require "open3"
require_relative "test_runner"
require_relative "test_fix_prompt_builder"
require_relative "file_parser"

module Calvin
  class TestFixLoop
    SYSTEM_PROMPT_PATH = File.expand_path(
      "../../config/prompts/rails/fix_test_system.md", __FILE__
    )

    def initialize(branch:, rails_root:, github:, mistral:, max_attempts: 2)
      @branch        = branch
      @rails_root    = rails_root
      @github        = github
      @mistral       = mistral
      @max_attempts  = max_attempts
      @system_prompt = File.read(SYSTEM_PROMPT_PATH)
    end

    def run
      fix_attempts = 0
      last_output  = ""

      loop do
        result      = TestRunner.new(rails_root: @rails_root).run
        last_output = result[:output]
        run_number  = fix_attempts + 1

        Calvin::LOG.info "TestFixLoop run #{run_number}/#{@max_attempts + 1}: #{result[:success] ? 'PASS' : 'FAIL'}"

        return { passed: true,  fix_attempts: fix_attempts, last_output: last_output } if result[:success]

        return { passed: false, fix_attempts: fix_attempts, last_output: last_output } if fix_attempts >= @max_attempts

        fix_attempts += 1
        fix_and_commit(result[:failures], fix_attempts)
      end
    end

    private

    def fix_and_commit(failures, attempt_number)
      Calvin::LOG.info "TestFixLoop: costruisco prompt fix (attempt #{attempt_number}) per #{failures.size} failure(s)"

      ctx = TestFixPromptBuilder.build(
        failures:      failures,
        github:        @github,
        branch:        @branch,
        system_prompt: @system_prompt
      )

      # system_prompt passato come system message — non come user message.
      # Senza questo, le istruzioni critiche (no destroy_all, no timestamp, ecc.)
      # non arrivano al modello.
      response = @mistral.complete_messages(
        [
          { role: "system", content: ctx[:system] },
          { role: "user",   content: ctx[:prompt] }
        ],
        temperature: Calvin::CONFIG.dig(:sampling, :temperature, :test_fix) || 0.0
      )

      files = FileParser.parse(response[:content].to_s)
      if files.empty?
        Calvin::LOG.warn "TestFixLoop attempt #{attempt_number}: il modello non ha prodotto FILE: blocks"
        return
      end

      Calvin::LOG.info "TestFixLoop: commit #{files.size} fix file(s) su #{@branch}"
      @github.commit_files_atomically(
        files,
        message: "fix(tests): attempt #{attempt_number} — auto test fix",
        branch:  @branch
      )
    rescue => e
      Calvin::LOG.warn "TestFixLoop fix_and_commit error: #{e.class} — #{e.message}"
    end
  end
end
