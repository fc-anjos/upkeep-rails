# frozen_string_literal: true

require "json"
require "test_helper"

class UpkeepSubscriptionTest < ActionDispatch::IntegrationTest
  setup do
    LobstersSeedData.call
    @story = seeded_story
    @user = seeded_user
  end

  test "anonymous and logged in pages register current subscriptions with bounded reports" do
    get "/"
    assert_response :success
    anonymous = current_subscription!

    sign_in_as @user
    get @story.comments_path
    assert_response :success
    logged_in = current_subscription!

    assert_acceptance_report(anonymous, expected_path: "/")
    assert_acceptance_report(logged_in, expected_path: @story.comments_path)
    refute_equal anonymous.metadata.fetch(:stream_name), logged_in.metadata.fetch(:stream_name)
  end

  test "cookie tag filters enter replay without leaking unrelated cookies" do
    cookies[:tag_filters] = "meta"
    cookies[:oauth_state] = "unread-cookie-secret"

    get "/"
    assert_response :success

    subscription = current_subscription!
    recipe_json = JSON.generate(page_recipe(subscription).to_h)

    assert_includes subscription.graph.summary.fetch(:dependency_sources), "cookie"
    assert_includes recipe_json, "tag_filters=meta"
    refute_includes recipe_json, "unread-cookie-secret"
    assert_acceptance_report(subscription, expected_path: "/")
  end

  test "comment mutation after subscription delivers through current runtime" do
    sign_in_as @user
    get @story.comments_path
    assert_response :success
    current_subscription!

    assert_difference -> { Comment.count }, 1 do
      post "/comments", params: {
        story_id: @story.short_id,
        comment: "upkeep acceptance comment"
      }, headers: XHR_HEADERS
    end

    assert_response :success
    Upkeep::Rails.drain_delivery!
  end

  private
    def current_subscription!
      marker = response.body[%r{<script type="application/json" data-upkeep-subscription>(.*?)</script>}m, 1]
      assert marker, "expected current Upkeep subscription marker"

      payload = JSON.parse(marker)
      Upkeep::Rails.subscriptions.fetch(payload.fetch("subscription_id"))
    end

    def assert_acceptance_report(subscription, expected_path:)
      report = subscription.graph.report
      replay_reports = report.fetch(:frames).filter_map { |frame| frame.dig(:replay_recipe, :replay) }
      replay_bytes = replay_reports.sum { |replay| replay.fetch(:bytes) }

      assert_empty subscription.recorder.refused_boundaries
      assert_equal expected_path, subscription.metadata.fetch(:path)
      assert_operator report.fetch(:summary).fetch(:frames), :>, 0
      assert_operator report.fetch(:summary).fetch(:dependencies), :>, 0
      assert_operator replay_reports.size, :>, 0
      assert_operator replay_bytes, :>, 0
      assert_operator replay_bytes, :<, 250_000
      assert_includes report.fetch(:summary).fetch(:replay_recipe_kinds), "page"
      lifecycle_sources = report.fetch(:summary).fetch(:dependency_sources) & %w[
        active_record_collection
        active_record_query
        active_record_attribute
      ]
      assert_operator lifecycle_sources.size, :>, 0
    end

    def page_recipe(subscription)
      page_frame = subscription.graph.frame_nodes.find { |frame| frame.payload.fetch(:kind) == "page" }
      page_frame.payload.fetch(:recipe)
    end
end
