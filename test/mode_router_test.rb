# frozen_string_literal: true

require_relative "test_helper"

class ModeRouterTest < Minitest::Test
  def test_explore_label_routes_to_explore_issue
    assert_equal :explore_issue, Calvin::ModeRouter.for_labels(["calvin"])
  end

  def test_explore_label_among_others
    assert_equal :explore_issue, Calvin::ModeRouter.for_labels(%w[backend calvin task])
  end

  def test_unknown_without_calvin_label
    assert_equal :unknown, Calvin::ModeRouter.for_labels(%w[backend task])
  end

  def test_unknown_with_empty_labels
    assert_equal :unknown, Calvin::ModeRouter.for_labels([])
  end

  def test_label_comes_from_config
    assert_equal Calvin::CONFIG.dig(:routing, :labels, :explore), Calvin::ModeRouter::LABEL_EXPLORE
  end
end
