# frozen_string_literal: true

require "test_helper"

class UpkeepSubscriptionTest < ActionDispatch::IntegrationTest
  setup do
    LobstersSeedData.call
  end

  test "anonymous feed injects a verifiable context token" do
    get "/"
    assert_response :success

    assert_verified_context_token
  end

  test "story page injects a verifiable context token" do
    get seeded_story.comments_path
    assert_response :success

    assert_verified_context_token
  end

  private
    def assert_verified_context_token
      token = response.body[/data-context-token="([^"]+)"/, 1]

      assert token, "expected Upkeep context token"
      assert Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    end
end
