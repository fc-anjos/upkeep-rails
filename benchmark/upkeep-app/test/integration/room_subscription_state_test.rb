# frozen_string_literal: true

require "test_helper"

class RoomSubscriptionStateTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(name: "alice", email: "alice@example.com", password: "secret123")
    @room = Room.create!(name: "General")
    @room.messages.create!(body: "hello", user: @user)
  end

  teardown do
    Message.delete_all
    Room.delete_all
    User.delete_all
  end

  test "room message fragments stay request-free and none-tier" do
    post "/sessions",
      params: { email: @user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    get "/rooms/#{@room.id}"
    assert_response :success

    token = response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "expected context token in room response"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "expected signed context token to verify"

    fragment_hashes = Upkeep.subscription_store.fragment_hashes(payload["sub"])
    assert fragment_hashes.present?, "expected fragment hashes for room subscription"

    message_fragments = fragment_hashes.select { |fragment_id, _| fragment_id.start_with?("message_") }
    assert message_fragments.any?, "expected message fragments in #{fragment_hashes.inspect}"
    assert message_fragments.values.all?(&:present?),
      "expected message fragments to carry compile-time hashes"

    manifests = message_fragments.transform_values do |fragment_hash|
      Upkeep::CompileTime::Manifest::Registry.lookup(fragment_hash)
    end
    assert manifests.values.all?,
      "expected manifest entries for #{message_fragments.inspect}, got #{manifests.transform_values(&:inspect)}"

    dispatch_state = Upkeep.subscription_store.fetch_for_relay(payload["sub"])
    assert dispatch_state.present?, "expected dispatch-safe subscription state"

    shared_message_fragments = dispatch_state.fragment_locals_digests.keys.grep(/\Amessage_/)
    assert shared_message_fragments.any?,
      "expected message digests in #{dispatch_state.fragment_locals_digests.inspect}"

    message_modes = dispatch_state.fragment_render_modes.slice(*shared_message_fragments)
    assert_equal [ "request_free" ], message_modes.values.uniq.sort,
      "expected request_free message fragments, got #{message_modes.inspect}"

    message_tiers = dispatch_state.fragment_identity_tiers.slice(*shared_message_fragments)
    assert_equal [ "none" ], message_tiers.values.uniq.sort,
      "expected none message fragments, got #{message_tiers.inspect}"
  end

  test "same-user repeated room loads reuse subscription identity and mint a fresh endpoint" do
    post "/sessions",
      params: { email: @user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    first = subscription_payload_for("/rooms/#{@room.id}")
    second = subscription_payload_for("/rooms/#{@room.id}")

    assert_equal first["sub"], second["sub"],
      "same-user room reloads must join the same subscription identity for sibling-endpoint chat delivery"
    refute_equal first["ep"], second["ep"]
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
