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

  def test_subscribes_to_server_derived_stream
    identity = Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: "user-1")
    stub_connection(current_user: "user-1")

    subscribe client_subscriber_id: "attacker"

    assert subscription.confirmed?
    assert_has_stream identity.stream_name
    refute Upkeep::Rails.transport.connected?("attacker")
  end

  def test_unsubscribe_keeps_subscription_state_out_of_transport
    identity = Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: "user-1")
    stub_connection(current_user: "user-1")
    subscribe

    unsubscribe

    refute Upkeep::Rails.transport.connected?(identity.subscriber_id)
  end

  def test_rejects_connections_without_canonical_server_identity
    stub_connection

    subscribe

    assert subscription.rejected?
    assert_no_streams
    assert_equal 0, Upkeep::Rails.transport.summary.fetch(:adapter_overrides)
  end

  def test_rejects_nil_server_identifier_values
    stub_connection(current_user: nil)

    subscribe

    assert subscription.rejected?
    assert_no_streams
    assert_equal 0, Upkeep::Rails.transport.summary.fetch(:adapter_overrides)
  end
end
