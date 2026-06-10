# frozen_string_literal: true

require "test_helper"

class SubscriberIdentityTest < Minitest::Test
  FakeRequest = Struct.new(:session, :cookies, keyword_init: true)
  FakeConnection = Struct.new(:request, :current_user, keyword_init: true)
  FakeUser = Struct.new(:id)

  # Strict double for the public surface of ActionCable::Connection::Base on
  # Rails 7.1-8.x: `env` is public, `request` is private. The private method
  # raises so any send-to-private regression in SubscribeContext fails loudly.
  class PublicSurfaceConnection
    attr_reader :env, :current_user

    def initialize(env:, current_user: nil)
      @env = env
      @current_user = current_user
    end

    private

    def request
      raise NotImplementedError, "private ActionCable request must not be reached"
    end
  end

  def setup
    Upkeep::Rails.configuration.clear_identities!
  end

  def teardown
    Upkeep::Rails.configuration.clear_identities!
  end

  def test_declared_session_identity_matches_request_and_connection
    Upkeep::Rails.configuration.identify :user, session: :user_id do
      subscribe { |connection| connection.session[:user_id] }
    end
    recorder = recorder_with(Upkeep::Dependencies::SessionValue.new(key: :user_id, value: 42))
    decision = identity.decision_for(nil, recorder: recorder)

    request_identity = identity.derive_from_request(nil, recorder: recorder, decision: decision)
    connection = FakeConnection.new(request: FakeRequest.new(session: { user_id: 42 }, cookies: {}))
    subscription = subscription_for(request_identity, recorder, identity_names: ["user"])

    assert_equal ["session"], decision.identity_sources
    assert_equal ["user"], decision.identity_names
    assert_equal request_identity.subscriber_id, identity.derive_for_subscription(connection, subscription).subscriber_id
  end

  def test_declared_nil_session_identity_stays_anonymous_public
    Upkeep::Rails.configuration.identify :user, session: :user_id do
      subscribe { |connection| connection.session[:user_id] }
    end
    recorder = recorder_with(Upkeep::Dependencies::SessionValue.new(key: :user_id, value: nil))
    decision = identity.decision_for(nil, recorder: recorder)

    request_identity = identity.derive_from_request(nil, recorder: recorder, decision: decision)

    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE, decision.mode
    assert_equal true, decision.anonymous
    assert_empty decision.identity_sources
    assert_empty decision.identity_names
    assert_match(/\Aaction_cable:/, request_identity.subscriber_id)
    assert_equal "public", recorder.identity_signature(Upkeep::Runtime::Recorder::REQUEST_NODE_ID)
  end

  def test_declared_false_session_identity_is_present_by_default
    Upkeep::Rails.configuration.identify :user, session: :user_id do
      subscribe { |connection| connection.session[:user_id] }
    end
    recorder = recorder_from_session_read(:user_id, false)
    decision = identity.decision_for(nil, recorder: recorder)

    request_identity = identity.derive_from_request(nil, recorder: recorder, decision: decision)
    connection = FakeConnection.new(request: FakeRequest.new(session: { user_id: false }, cookies: {}))
    subscription = subscription_for(request_identity, recorder, identity_names: ["user"])

    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::IDENTIFIED_MODE, decision.mode
    assert_equal ["user"], decision.identity_names
    assert_equal request_identity.subscriber_id, identity.derive_for_subscription(connection, subscription).subscriber_id
  end

  def test_absent_if_can_mark_non_nil_identity_values_absent
    Upkeep::Rails.configuration.identify :user, session: :user_id do
      absent_if { |value| value.nil? || value == false }
      subscribe { |connection| connection.session[:user_id] }
    end
    recorder = recorder_from_session_read(:user_id, false)
    decision = identity.decision_for(nil, recorder: recorder)

    request_identity = identity.derive_from_request(nil, recorder: recorder, decision: decision)

    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE, decision.mode
    assert_empty decision.identity_names
    assert_match(/\Aaction_cable:/, request_identity.subscriber_id)
    assert_equal "public", recorder.identity_signature(Upkeep::Runtime::Recorder::REQUEST_NODE_ID)
  end

  def test_absent_connection_identity_does_not_authorize_identified_subscription
    Upkeep::Rails.configuration.identify :user, session: :user_id do
      absent_if { |value| value.nil? || value == false }
      subscribe { |connection| connection.session[:user_id] }
    end
    recorder = recorder_from_session_read(:user_id, "alice")
    request_identity = identity.derive_from_request(nil, recorder: recorder)
    connection = FakeConnection.new(request: FakeRequest.new(session: { user_id: false }, cookies: {}))
    subscription = subscription_for(request_identity, recorder, identity_names: ["user"])

    assert_raises(Upkeep::Rails::Cable::UnidentifiedSubscriber) do
      identity.derive_for_subscription(connection, subscription)
    end
  end

  def test_declared_cookie_identity_matches_request_and_connection
    Upkeep::Rails.configuration.identify :account, cookie: :account_id do
      subscribe { |connection| connection.cookies[:account_id] }
    end
    recorder = recorder_with(Upkeep::Dependencies::CookieValue.new(key: :account_id, value: "acct-1"))
    request_identity = identity.derive_from_request(nil, recorder: recorder)
    connection = FakeConnection.new(request: FakeRequest.new(session: {}, cookies: { account_id: "acct-1" }))
    subscription = subscription_for(request_identity, recorder, identity_names: ["account"])

    assert_equal request_identity.subscriber_id, identity.derive_for_subscription(connection, subscription).subscriber_id
  end

  def test_subscribe_context_builds_request_from_public_connection_env
    Upkeep::Rails.configuration.identify :user, session: :user_id do
      subscribe { |connection| connection.session[:user_id] }
    end
    recorder = recorder_from_session_read(:user_id, 42)
    request_identity = identity.derive_from_request(nil, recorder: recorder)
    connection = PublicSurfaceConnection.new(env: { "rack.session" => { user_id: 42 } })
    subscription = subscription_for(request_identity, recorder, identity_names: ["user"])

    assert_equal request_identity.subscriber_id, identity.derive_for_subscription(connection, subscription).subscriber_id
  end

  def test_subscribe_context_reads_cookies_from_public_connection_env
    Upkeep::Rails.configuration.identify :account, cookie: :account_id do
      subscribe { |connection| connection.cookies["account_id"] }
    end
    recorder = recorder_with(Upkeep::Dependencies::CookieValue.new(key: :account_id, value: "acct-1"))
    request_identity = identity.derive_from_request(nil, recorder: recorder)
    connection = PublicSurfaceConnection.new(env: { "HTTP_COOKIE" => "account_id=acct-1" })
    subscription = subscription_for(request_identity, recorder, identity_names: ["account"])

    assert_equal request_identity.subscriber_id, identity.derive_for_subscription(connection, subscription).subscriber_id
  end

  def test_subscribe_context_does_not_call_private_action_cable_request
    context = Upkeep::Rails::Cable::SubscribeContext.new(
      PublicSurfaceConnection.new(env: { "rack.session" => { user_id: 42 } })
    )

    refute context.respond_to?(:request)
    assert_raises(NoMethodError) { context.request }
    assert_equal 42, context.session[:user_id]
  end

  def test_subscribe_context_rejects_connection_without_public_request_or_env
    context = Upkeep::Rails::Cable::SubscribeContext.new(Object.new)

    assert_raises(Upkeep::Rails::Cable::UnidentifiedSubscriber) { context.session }
  end

  def test_undeclared_nil_current_identity_does_not_require_setup
    recorder = recorder_with(Upkeep::Dependencies::CurrentAttribute.new(owner: "Current", name: :user, value: nil))
    decision = identity.decision_for(nil, recorder: recorder)

    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE, decision.mode
    assert_nil decision.deopt_reason
    assert_empty decision.identity_sources
  end

  def test_undeclared_warden_identity_requires_setup
    recorder = recorder_with(Upkeep::Dependencies::WardenUser.new(scope: :user, user: FakeUser.new(7)))
    decision = identity.decision_for(nil, recorder: recorder)

    assert_equal "identity_setup_required", decision.deopt_reason
    assert_equal ["warden_user"], decision.identity_sources
    assert_raises(Upkeep::Rails::Cable::UnidentifiedSubscriber) do
      identity.derive_from_request(nil, recorder: recorder, decision: decision)
    end
  end

  private

  def identity
    Upkeep::Rails::Cable::SubscriberIdentity
  end

  def recorder_with(dependency)
    Upkeep::Runtime::Recorder.new.tap do |recorder|
      recorder.record_dependency(dependency)
      recorder.flush_pending_dependencies
    end
  end

  def recorder_from_session_read(key, value)
    _result, recorder = Upkeep::Runtime::Observation.capture_request do
      Upkeep::Runtime::Ambient.record_session(key, value)
    end
    recorder
  end

  def subscription_for(subscriber_identity, recorder, identity_names:)
    Upkeep::Subscriptions::Subscription.new(
      "subscription-test",
      subscriber_identity.subscriber_id,
      recorder,
      recorder.graph,
      {
        identity_mode: Upkeep::Rails::Cable::SubscriberIdentity::IDENTIFIED_MODE,
        identity_names: identity_names,
        stream_name: subscriber_identity.stream_name
      }
    )
  end
end
