# frozen_string_literal: true

require "test_helper"
require "action_cable/channel/test_case"

ActionCable.server.config.cable = { "adapter" => "test" }

class CableChannelTest < ActionCable::Channel::TestCase
  tests Upkeep::Rails::Cable::Channel

  def setup
    super
    Upkeep::Rails.reset_runtime!
  end

  def test_subscribes_to_server_subscription_stream
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")

    subscribe subscription_id: subscription_record.id, client_subscriber_id: "attacker"

    assert subscription.confirmed?
    assert_has_stream "upkeep:test:user-1"
    refute Upkeep::Rails.transport.connected?("attacker")
  end

  def test_unsubscribe_keeps_subscription_state_out_of_transport
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")
    subscribe subscription_id: subscription_record.id

    unsubscribe

    refute Upkeep::Rails.transport.connected?(subscription_record.subscriber_id)
  end

  def test_rejects_subscriptions_without_server_record
    stub_connection(current_user: "user-1")

    subscribe subscription_id: "missing"

    assert subscription.rejected?
    assert_no_streams
    assert_equal 0, Upkeep::Rails.transport.summary.fetch(:adapter_overrides)
  end

  def test_rejects_subscriptions_without_subscription_id
    registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")

    subscribe

    assert subscription.rejected?
    assert_no_streams
    assert_equal 0, Upkeep::Rails.transport.summary.fetch(:adapter_overrides)
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
