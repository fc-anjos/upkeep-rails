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

  def test_subscribe_does_not_write_liveness_metadata
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    Upkeep::Rails.subscriptions.touch(subscription_record.id, now: Time.utc(2026, 1, 1))
    stub_connection(current_user: "user-1")

    subscribe subscription_id: subscription_record.id

    assert subscription.confirmed?
    assert_equal "2026-01-01T00:00:00Z",
      Upkeep::Rails.subscriptions.fetch(subscription_record.id).metadata.fetch("last_seen_at")
  end

  def test_subscribe_activates_subscription_store
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    activated_ids = []
    Upkeep::Rails.subscriptions.define_singleton_method(:activate) do |subscription_id|
      activated_ids << subscription_id
      true
    end
    stub_connection(current_user: "user-1")

    subscribe subscription_id: subscription_record.id

    assert subscription.confirmed?
    assert_equal [subscription_record.id], activated_ids
  end

  def test_subscribes_to_public_shared_streams_derived_from_the_server_subscription
    subscription_record = registered_subscription_with_public_frame(stream_name: "upkeep:test:user-1")
    shared_stream_name = Upkeep::SharedStreams.names_for_subscription(subscription_record).first
    stub_connection(current_user: "user-1")

    subscribe subscription_id: subscription_record.id

    assert subscription.confirmed?
    assert_has_stream "upkeep:test:user-1"
    assert_has_stream shared_stream_name
  end

  def test_subscribes_to_anonymous_public_subscription_without_connection_identity
    subscription_record = registered_subscription(
      stream_name: "upkeep:test:anonymous",
      metadata: {
        identity_mode: Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE,
        anonymous: true
      }
    )
    stub_connection(current_user: nil)

    subscribe subscription_id: subscription_record.id

    assert subscription.confirmed?
    assert_has_stream "upkeep:test:anonymous"
  end

  def test_rejects_identified_subscription_when_connection_identity_does_not_match
    alice = Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: "alice")
    subscription_record = registered_subscription(
      subscriber_id: alice.subscriber_id,
      stream_name: alice.stream_name,
      metadata: { identity_mode: Upkeep::Rails::Cable::SubscriberIdentity::IDENTIFIED_MODE }
    )
    stub_connection(current_user: "bob")

    subscribe subscription_id: subscription_record.id

    assert subscription.rejected?
    assert_no_streams
  end

  def test_unsubscribe_keeps_subscription_state_out_of_transport
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")
    subscribe subscription_id: subscription_record.id

    unsubscribe

    refute Upkeep::Rails.transport.connected?(subscription_record.subscriber_id)
    assert_raises(KeyError) { Upkeep::Rails.subscriptions.fetch(subscription_record.id) }
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

  def registered_subscription(stream_name:, subscriber_id: nil, metadata: {})
    Upkeep::Rails.subscriptions.register(
      subscriber_id: subscriber_id || "subscriber-#{stream_name}",
      recorder: Upkeep::Runtime::Recorder.new,
      metadata: { stream_name: stream_name }.merge(metadata)
    )
  end

  def registered_subscription_with_public_frame(stream_name:)
    recorder = Upkeep::Runtime::Recorder.new
    recipe = Upkeep::Replay::Recipe.new(
      kind: :render_site,
      frame_id: "site:public",
      target_kind: "render_site",
      target_id: "public",
      template: "widgets/_public"
    ) { "" }

    recorder.graph.add_node("site:public", kind: :frame, payload: { kind: "render_site", site_id: "public", recipe: recipe })
    recorder.graph.add_edge(Upkeep::Runtime::Recorder::REQUEST_NODE_ID, "site:public", reason: :contains)

    Upkeep::Rails.subscriptions.register(
      subscriber_id: "subscriber-#{stream_name}",
      recorder: recorder,
      metadata: {
        stream_name: stream_name,
        shared_stream_names: Upkeep::SharedStreams.names_for_recorder(recorder)
      }
    )
  end
end
