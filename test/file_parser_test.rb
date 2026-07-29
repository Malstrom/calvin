# frozen_string_literal: true

require_relative "test_helper"

class FileParserTest < Minitest::Test
  def test_parses_plain_blocks
    files = Calvin::FileParser.parse(fixture("response_plain.txt"))

    assert_equal ["app/services/magic_link_service.rb", "config/routes.rb"], files.map { |f| f[:path] }
    assert_includes files.first[:content], "class MagicLinkService"
    refute_includes files.first[:content], "FILE:"
  end

  # Regressione: il vecchio parser faceva `return fenced if fenced.any?`, quindi una
  # risposta con un blocco fenced e uno plain perdeva silenziosamente il secondo.
  def test_parses_fenced_and_plain_in_the_same_response
    files = Calvin::FileParser.parse(fixture("response_mixed.txt"))

    assert_equal ["app/models/user.rb", "app/services/user_creator.rb"], files.map { |f| f[:path] }
    assert_includes files[0][:content], "has_many :sessions"
    refute_includes files[0][:content], "```"
    assert_includes files[1][:content], "class UserCreator"
  end

  def test_pr_body_is_not_captured_as_file_content
    files = Calvin::FileParser.parse(fixture("response_plain.txt"))

    files.each { |f| refute_includes f[:content], "PR_BODY_START" }
    refute_includes files.last[:content], "What this does"
  end

  def test_parse_pr_body
    body = Calvin::FileParser.parse_pr_body(fixture("response_plain.txt"))

    assert_equal "## What this does\n\nAdds the magic link service.", body
  end

  def test_parse_pr_body_returns_nil_without_block
    assert_nil Calvin::FileParser.parse_pr_body("FILE: a.rb\nputs 1\n")
  end

  def test_ignores_file_mentions_inside_prose
    content = <<~TXT
      Some explanation mentioning FILE: with a description after it
      FILE: app/models/user.rb
      class User; end
    TXT

    files = Calvin::FileParser.parse(content)

    assert_equal ["app/models/user.rb"], files.map { |f| f[:path] }
  end

  def test_returns_empty_array_without_blocks
    assert_empty Calvin::FileParser.parse("Non ho trovato nulla da modificare.")
    assert_empty Calvin::FileParser.parse(nil)
  end

  # Una fence non chiusa (risposta troncata) non deve far sparire il blocco né
  # inghiottire il resto della risposta.
  def test_unclosed_fence_still_yields_the_block
    content = "FILE: app/models/user.rb\n```ruby\nclass User\n"

    files = Calvin::FileParser.parse(content)

    assert_equal 1, files.size
    assert_includes files.first[:content], "class User"
  end
end
