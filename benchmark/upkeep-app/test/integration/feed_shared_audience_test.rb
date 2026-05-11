# frozen_string_literal: true

require "test_helper"

class FeedSharedAudienceTest < ActionDispatch::IntegrationTest
  setup do
    FeedItem.delete_all
    FeedItem.create!(title: "One", body: "Body one")
  end

  teardown do
    FeedItem.delete_all
  end

  test "repeated feed loads reuse the same subscription identity and mint new endpoints" do
    first = subscription_payload_for("/feed")
    second = subscription_payload_for("/feed")

    assert_equal first["sub"], second["sub"],
      "shared feed benchmark surface must collapse repeated loads onto one subscription identity"
    refute_equal first["ep"], second["ep"],
      "each page load still needs its own endpoint for echo suppression"
    refute_equal first["ot"], second["ot"],
      "endpoint originator tokens must stay per-endpoint"
  end

  private

  def subscription_payload_for(path)
    get path
    assert_response :success

    token = response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "expected context token in #{path}"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "expected context token in #{path} to verify"
    payload
  end
end
