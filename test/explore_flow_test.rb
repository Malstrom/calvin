# frozen_string_literal: true

require_relative "test_helper"

# Test end-to-end del flow con doppi al posto di rete e modello.
# Serve a verificare il cablaggio dei 6 step: dry-transaction passa i keyword da uno step
# all'altro, quindi un argomento mancante si manifesta solo a runtime.
class ExploreFlowTest < Minitest::Test
  MODEL_RESPONSES = {
    explore: [
      '{"thought":"leggo il service esistente","tool":"read_file","args":{"path":"app/services/existing_service.rb"}}',
      '{"thought":"contesto sufficiente","tool":"done","args":{"modify":[],"create":["app/services/new_service.rb"],"reference":["app/services/existing_service.rb"]}}'
    ],
    implement: <<~OUT
      FILE: app/services/new_service.rb
      # frozen_string_literal: true

      # Nuovo service generato dal modello.
      class NewService
        def call
          true
        end
      end

      PR_BODY_START
      ## What this does

      Aggiunge NewService.
      PR_BODY_END
    OUT
  }.freeze

  # Doppio del client Mistral: risponde in sequenza alle chiamate explore e poi a implement,
  # registrando i messaggi per poter verificare cosa è finito nel prompt.
  class ScriptedMistral
    attr_reader :calls

    def initialize(explore:, implement:)
      @explore   = explore.dup
      @implement = implement
      @calls     = []
    end

    def complete_messages(messages, temperature: nil, cache_key: nil)
      @calls << { messages: messages, phase: cache_key ? :explore : :implement }
      content = cache_key ? @explore.shift : @implement
      { content: content, usage: { "prompt_tokens" => 500, "completion_tokens" => 200, "total_tokens" => 700 } }
    end

    def prompt_for(phase)
      @calls.select { |c| c[:phase] == phase }
            .flat_map { |c| c[:messages] }
            .map { |m| m[:content].to_s }
            .join("\n")
    end
  end

  # Doppio di GitHubClient: registra branch, commit e PR create.
  class FakeGitHub
    attr_reader :branches, :commits, :pulls, :labels

    def initialize(files: {})
      @files    = files
      @branches = []
      @commits  = []
      @pulls    = []
      @labels   = []
    end

    def get_file_content(path, ref: nil) = @files[path]
    def list_directory(path) = @files.keys.select { |k| k.start_with?("#{path}/") }.map { |k| File.basename(k) }
    def grep_files(_pattern, _path) = "ERROR: no matches"
    def default_branch = "main"

    def create_branch(name) = @branches << name

    def commit_files_atomically(files, message:, branch:)
      @commits << { files: files, message: message, branch: branch }
      "sha"
    end

    def create_pull_request(title:, body:, head:, base: nil)
      @pulls << { title: title, body: body, head: head }
      Struct.new(:html_url).new("https://github.com/Malstrom/synca/pull/7")
    end

    def add_label(number, label) = @labels << [number, label]
  end

  def setup
    ENV["CALVIN_VALIDATION_LEVEL"] = "static"
  end

  def teardown
    ENV.delete("CALVIN_VALIDATION_LEVEL")
    ENV.delete("CALVIN_DRY_RUN")
  end

  def test_happy_path_validates_then_opens_pr
    github = FakeGitHub.new(files: {
      "app/services/existing_service.rb" => "# frozen_string_literal: true\n\n# Existing.\nclass ExistingService\n  def call = true\nend\n"
    })
    mistral = ScriptedMistral.new(explore: MODEL_RESPONSES[:explore], implement: MODEL_RESPONSES[:implement])

    result = run_flow(github, mistral)

    assert result.success?, "flow fallito: #{result.failure if result.failure?}"
    value = result.value!

    assert_equal :success, value.status
    assert_equal true, value.meta(:validation_ok)
    assert_equal 0, value.meta(:repair_attempts)
    assert_equal ["app/services/new_service.rb"], value.files.map { |f| f[:path] }
    assert_equal "https://github.com/Malstrom/synca/pull/7", value.pr_url
    assert_equal 1, github.pulls.size
    assert_includes github.pulls.first[:body], "Validazione superata"
  end

  # Il modello produce un file rotto: la ladder lo intercetta, il repair lo corregge e solo
  # allora si apre la PR. È il comportamento che prima non esisteva.
  def test_red_gate_triggers_repair_before_pr
    broken = <<~OUT
      FILE: app/services/new_service.rb
      class NewService
        def call
      end

      PR_BODY_START
      ## What this does

      Rotto.
      PR_BODY_END
    OUT

    github  = FakeGitHub.new
    mistral = ScriptedMistral.new(
      explore: [
        '{"thought":"basta","tool":"done","args":{"modify":[],"create":["app/services/new_service.rb"],"reference":[]}}'
      ],
      implement: broken
    )
    # La stessa risposta viene usata anche per il repair: il file resta rotto.
    result = run_flow(github, mistral)

    assert result.success?, "con open_pr_when_red la PR si apre comunque"
    value = result.value!

    assert_equal :partial, value.status
    assert_equal false, value.meta(:validation_ok)
    assert_equal :syntax, value.meta(:validation_stage)
    assert_operator value.meta(:repair_attempts), :>, 0
    assert_includes github.labels.map(&:last), Calvin::CONFIG.dig(:validation, :red_label)
    assert_includes github.pulls.first[:body], "Validazione rossa"
  end

  def test_dry_run_opens_no_pr
    ENV["CALVIN_DRY_RUN"] = "true"
    github  = FakeGitHub.new
    mistral = ScriptedMistral.new(
      explore: ['{"thought":"basta","tool":"done","args":{"modify":[],"create":["app/services/new_service.rb"],"reference":[]}}'],
      implement: MODEL_RESPONSES[:implement]
    )

    result = run_flow(github, mistral)

    assert result.success?
    assert_equal :dry_run, result.value!.status
    assert_empty github.pulls
    assert_empty github.commits
  end

  # ── knowledge_source ──────────────────────────────────────────────────────────

  # I gate del Validator sono l'unica fonte sempre attiva: senza RAG (Supabase assente o
  # senza chunk sopra soglia) il run resta comunque valido, ma il fatto va tracciato invece
  # di sparire in silenzio.
  def test_knowledge_reports_only_gates_without_rag
    github  = FakeGitHub.new
    mistral = ScriptedMistral.new(
      explore: ['{"thought":"basta","tool":"done","args":{"modify":[],"create":["app/services/new_service.rb"],"reference":[]}}'],
      implement: MODEL_RESPONSES[:implement]
    )

    result = run_flow(github, mistral)

    assert_equal ["gates"], result.value!.meta(:knowledge)
  end

  def test_failure_when_model_returns_no_file_blocks
    github  = FakeGitHub.new
    mistral = ScriptedMistral.new(
      explore: ['{"thought":"basta","tool":"done","args":{"modify":[],"create":[],"reference":[]}}'],
      implement: "Non ho nulla da modificare."
    )

    result = run_flow(github, mistral)

    assert result.failure?
    assert_equal :parse_files, result.failure[:step]
  end

  private

  def run_flow(github, mistral, workspace: nil)
    Calvin::ExploreFlow.new.call(
      issue:     Issue.build(number: 7, title: "Aggiungi NewService", body: "Serve un service."),
      github:    github,
      stack:     "rails",
      workspace: workspace,
      mistral:   mistral
    )
  end
end
