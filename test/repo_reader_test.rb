# frozen_string_literal: true

require_relative "test_helper"

class RepoReaderTest < Minitest::Test
  def test_prefers_local_clone
    api = FakeReader.new(files: { "app/models/user.rb" => "# dalla API\n" })

    with_workspace(files: { "app/models/user.rb" => "# dal clone\n" }) do |ws|
      reader = Calvin::RepoReader.new(workspace: ws, github: api)

      assert reader.local?
      assert_equal :workspace, reader.source
      assert_includes reader.get_file_content("app/models/user.rb"), "dal clone"
    end
  end

  # Un file che esiste su GitHub ma non nel working tree (es. generato da un altro branch)
  # deve comunque essere leggibile.
  def test_falls_back_to_api_for_file_missing_from_clone
    api = FakeReader.new(files: { "app/models/ghost.rb" => "# dalla API\n" })

    with_workspace(files: { "app/models/user.rb" => "# dal clone\n" }) do |ws|
      reader = Calvin::RepoReader.new(workspace: ws, github: api)

      assert_includes reader.get_file_content("app/models/ghost.rb"), "dalla API"
    end
  end

  def test_uses_api_when_clone_missing
    api    = FakeReader.new(files: { "app/models/user.rb" => "# dalla API\n" }, dirs: { "app" => ["models"] })
    ws     = Calvin::Workspace.new(target_path: "/tmp/calvin-missing-#{Process.pid}")
    reader = Calvin::RepoReader.new(workspace: ws, github: api)

    refute reader.local?
    assert_equal :api, reader.source
    assert_includes reader.get_file_content("app/models/user.rb"), "dalla API"
    assert_equal ["models"], reader.list_directory("app")
  end

  def test_ref_always_goes_through_the_api
    api = FakeReader.new(files: { "app/models/user.rb" => "# dalla API\n" })

    with_workspace(files: { "app/models/user.rb" => "# dal clone\n" }) do |ws|
      reader = Calvin::RepoReader.new(workspace: ws, github: api)

      assert_includes reader.get_file_content("app/models/user.rb", ref: "some-branch"), "dalla API"
    end
  end

  def test_works_without_workspace
    api    = FakeReader.new(files: { "a.rb" => "x" })
    reader = Calvin::RepoReader.new(workspace: nil, github: api)

    refute reader.local?
    assert_equal "x", reader.get_file_content("a.rb")
  end
end
