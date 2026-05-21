# frozen_string_literal: true

require "test_helper"
require "action_cable/channel/test_case"

ActionCable.server.config.cable = { "adapter" => "test" }

class CableChannelTest < ActionCable::Channel::TestCase
  tests Upkeep::Rails::Cable::Channel

  class ActivationVisibleStore
    attr_reader :reverse_index

    def initialize(subscription)
      @subscription = subscription
      @reverse_index = Upkeep::Subscriptions::ReverseIndex.new
    end

    def fetch(id)
      raise KeyError, id unless subscription&.id == id

      subscription
    end

    def activate(id)
      fetch(id)
      reverse_index.index(subscription)
      true
    end

    def unregister(ids)
      Array(ids).each { |id| reverse_index.delete_subscription(id) }
      @subscription = nil
      Array(ids).size
    end

    def reset
      @reverse_index = Upkeep::Subscriptions::ReverseIndex.new
    end

    def shutdown
      true
    end

    private

    attr_reader :subscription
  end

  def setup
    super
    Upkeep::Rails.configuration.clear_identities!
    Upkeep::Rails.reset_runtime!
  end

  def teardown
    Upkeep::Rails.configuration.clear_identities!
    Upkeep::Rails.reset_runtime!
    super
  end

  def test_subscribes_to_server_subscription_stream
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")

    subscribe subscription_params(subscription_record, client_subscriber_id: "attacker")

    assert subscription.confirmed?
    assert_has_stream "upkeep:test:user-1"
    refute Upkeep::Rails.transport.connected?("attacker")
  end

  def test_subscribe_does_not_write_liveness_metadata
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    Upkeep::Rails.subscriptions.touch(subscription_record.id, now: Time.utc(2026, 1, 1))
    stub_connection(current_user: "user-1")

    subscribe subscription_params(subscription_record)

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

    subscribe subscription_params(subscription_record)

    assert subscription.confirmed?
    assert_equal [subscription_record.id], activated_ids
  end

  def test_channel_activation_makes_subscription_visible_to_lookup
    subscription_record = lookup_subscription(stream_name: "upkeep:test:user-1")
    store = ActivationVisibleStore.new(subscription_record)
    Upkeep::Rails.instance_variable_set(:@subscriptions, store)
    stub_connection(current_user: "user-1")

    assert_empty store.reverse_index.entries_for([lookup_change])

    subscribe subscription_params(subscription_record)

    assert subscription.confirmed?
    assert_equal [subscription_record.id], store.reverse_index.entries_for([lookup_change]).map(&:subscription_id)
  end

  def test_subscribes_to_public_shared_streams_derived_from_the_server_subscription
    subscription_record = registered_subscription_with_public_frame(stream_name: "upkeep:test:user-1")
    shared_stream_name = Upkeep::SharedStreams.names_for_subscription(subscription_record).first
    stub_connection(current_user: "user-1")

    subscribe subscription_params(subscription_record)

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

    subscribe subscription_params(subscription_record)

    assert subscription.confirmed?
    assert_has_stream "upkeep:test:anonymous"
  end

  def test_rejects_identified_subscription_when_connection_identity_does_not_match
    configure_user_identity
    alice = Upkeep::Rails::Cable::SubscriberIdentity.for_components([
      { name: "user", kind: "identity", value: "alice" }
    ])
    subscription_record = registered_subscription(
      subscriber_id: alice.subscriber_id,
      stream_name: alice.stream_name,
      metadata: {
        identity_mode: Upkeep::Rails::Cable::SubscriberIdentity::IDENTIFIED_MODE,
        identity_names: ["user"]
      }
    )
    stub_connection(current_user: "bob")

    subscribe subscription_params(subscription_record)

    assert subscription.rejected?
    assert_no_streams
  end

  def test_rejects_subscription_with_missing_activation_token
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")
    events = []
    listener = ActiveSupport::Notifications.subscribe("subscribe_channel.upkeep") { |event| events << event }

    subscribe subscription_id: subscription_record.id

    assert subscription.rejected?
    assert_no_streams
    assert_equal "missing_activation_token", events.first.payload.fetch(:reject_reason)
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
  end

  def test_rejects_subscription_with_mismatched_activation_token
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")
    events = []
    listener = ActiveSupport::Notifications.subscribe("subscribe_channel.upkeep") { |event| events << event }

    subscribe subscription_id: subscription_record.id,
      activation_token: Upkeep::Rails::ActivationToken.generate("subscription-other")

    assert subscription.rejected?
    assert_no_streams
    assert_equal "invalid_activation_token", events.first.payload.fetch(:reject_reason)
  ensure
    ActiveSupport::Notifications.unsubscribe(listener) if listener
  end

  def test_unsubscribe_keeps_subscription_state_out_of_transport
    subscription_record = registered_subscription(stream_name: "upkeep:test:user-1")
    stub_connection(current_user: "user-1")
    subscribe subscription_params(subscription_record)

    unsubscribe

    refute Upkeep::Rails.transport.connected?(subscription_record.subscriber_id)
    assert_raises(Upkeep::Subscriptions::NotFound) { Upkeep::Rails.subscriptions.fetch(subscription_record.id) }
  end

  def test_rejects_subscriptions_without_server_record
    stub_connection(current_user: "user-1")

    subscribe subscription_id: "missing",
      activation_token: Upkeep::Rails::ActivationToken.generate("missing")

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

  def configure_user_identity
    Upkeep::Rails.configuration.identify :user, current: ["Current", :user] do
      subscribe { |connection| connection.current_user }
    end
  end

  def registered_subscription(stream_name:, subscriber_id: nil, metadata: {})
    Upkeep::Rails.subscriptions.register(
      subscriber_id: subscriber_id || "subscriber-#{stream_name}",
      recorder: Upkeep::Runtime::Recorder.new,
      metadata: { stream_name: stream_name }.merge(metadata)
    )
  end

  def subscription_params(subscription, **extra)
    {
      subscription_id: subscription.id,
      activation_token: Upkeep::Rails::ActivationToken.generate(subscription)
    }.merge(extra)
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

  def lookup_subscription(stream_name:)
    recorder = Upkeep::Runtime::Recorder.new
    recorder.record_dependency(
      Upkeep::Dependencies::ActiveRecordAttribute.new(
        table: "activation_cards",
        model: "ActivationCard",
        id: 1,
        attribute: "title"
      )
    )

    Upkeep::Subscriptions::Subscription.new(
      "subscription-activation-visible",
      "subscriber-#{stream_name}",
      recorder,
      recorder.graph,
      { stream_name: stream_name }
    )
  end

  def lookup_change
    {
      type: "update",
      table: "activation_cards",
      id: 1,
      changed_attributes: ["title"],
      old_values: { "title" => "Plan" },
      new_values: { "title" => "Plan v2" }
    }
  end
end
