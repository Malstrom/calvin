# frozen_string_literal: true

require_relative "test_helper"

class ContextBuilderTest < Minitest::Test
  # Regressione: ExploreFlow chiamava build(issue) senza reader, quindi
  # NEXT_MIGRATION_VERSION non entrava mai nel prompt e il modello doveva indovinare
  # il timestamp floor esplorando db/migrate.
  def test_injects_next_migration_version
    reader = FakeReader.new(dirs: { "db/migrate" => %w[20260101000000_a.rb 20260102000000_b.rb] })

    prompt = Calvin::ContextBuilder.build(Issue.build, reader: reader)

    assert_includes prompt, "NEXT_MIGRATION_VERSION: 20260102000001"
    assert prompt.start_with?("NEXT_MIGRATION_VERSION:"), "la versione va in testa al prompt"
  end

  def test_next_version_is_last_plus_one
    reader = FakeReader.new(dirs: { "db/migrate" => %w[20260615093000_x.rb] })

    assert_equal "20260615093001", Calvin::ContextBuilder.next_migration_version(reader)
  end

  def test_next_version_falls_back_to_now_without_migrations
    reader = FakeReader.new(dirs: { "db/migrate" => [] })

    assert_match(/\A\d{14}\z/, Calvin::ContextBuilder.next_migration_version(reader))
  end

  def test_ignores_files_without_timestamp
    reader = FakeReader.new(dirs: { "db/migrate" => %w[.keep schema.rb 20260101000000_a.rb] })

    assert_equal "20260101000001", Calvin::ContextBuilder.next_migration_version(reader)
  end

  def test_builds_task_and_description_sections
    prompt = Calvin::ContextBuilder.build(Issue.build(title: "Aggiungi endpoint", body: "Dettagli"))

    assert_includes prompt, "# Task: Aggiungi endpoint"
    assert_includes prompt, "## Description\n\nDettagli"
    refute_includes prompt, "NEXT_MIGRATION_VERSION", "senza reader non c'è nulla da iniettare"
  end

  def test_omits_description_when_body_empty
    prompt = Calvin::ContextBuilder.build(Issue.build(title: "Solo titolo", body: ""))

    refute_includes prompt, "## Description"
  end

  def test_raises_when_title_and_body_are_empty
    error = assert_raises(RuntimeError) do
      Calvin::ContextBuilder.build(Issue.build(number: 7, title: "", body: ""))
    end

    assert_includes error.message, "#7"
  end

  def test_github_client_keyword_still_accepted
    reader = FakeReader.new(dirs: { "db/migrate" => %w[20260101000000_a.rb] })

    prompt = Calvin::ContextBuilder.build(Issue.build, github_client: reader)

    assert_includes prompt, "NEXT_MIGRATION_VERSION: 20260101000001"
  end
end
