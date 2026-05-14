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

  test "streams from the server subscription record" do
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-#{@user.id}")
    stub_connection(current_user: @user)

    subscribe subscription_id: subscription_record.id, client_subscriber_id: "attacker"

    assert subscription.confirmed?
    assert_has_stream "upkeep:test:user-#{@user.id}"
    refute Upkeep::Rails.transport.connected?("attacker")
  end

  test "keeps connection state out of transport on unsubscribe" do
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-#{@user.id}")
    stub_connection(current_user: @user)
    subscribe subscription_id: subscription_record.id

    unsubscribe

    refute Upkeep::Rails.transport.connected?(subscription_record.subscriber_id)
    assert_raises(KeyError) { Upkeep::Rails.subscriptions.fetch(subscription_record.id) }
  end

  test "rejects subscriptions without server record" do
    stub_connection(current_user: @user)

    subscribe subscription_id: "missing"

    assert subscription.rejected?
    assert_no_streams
  end

  private

  def registered_subscription(stream_name:)
    Upkeep::Rails.subscriptions.register(
      subscriber_id: "subscriber-#{stream_name}",
      recorder: Upkeep::Runtime::Recorder.new,
      metadata: { stream_name: stream_name }
    )
  end
end
