# frozen_string_literal: true

require "test_helper"
require "action_cable/channel/test_case"

class UpkeepChannelTest < ActionCable::Channel::TestCase
  tests Upkeep::Rails::Cable::Channel

  PASSWORD = "secret123"

  setup do
    Upkeep::Rails.reset_runtime!
    @user = User.create!(name: "Alice", email: "alice-channel@example.com", password: PASSWORD)
  end

  test "streams from the server-derived user identity" do
    identity = Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: @user)
    stub_connection(current_user: @user)

    subscribe client_subscriber_id: "attacker"

    assert subscription.confirmed?
    assert_has_stream identity.stream_name
    assert Upkeep::Rails.transport.connected?(identity.subscriber_id)
    refute Upkeep::Rails.transport.connected?("attacker")
  end

  test "disconnects the transport connection on unsubscribe" do
    identity = Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: @user)
    stub_connection(current_user: @user)
    subscribe

    unsubscribe

    refute Upkeep::Rails.transport.connected?(identity.subscriber_id)
  end
end
