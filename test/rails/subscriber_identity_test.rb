# frozen_string_literal: true

require "test_helper"

class SubscriberIdentityTest < Minitest::Test
  FakeRequest = Struct.new(:session, :cookies, keyword_init: true)
  FakeConnection = Struct.new(:request, :current_user, keyword_init: true)
  FakeUser = Struct.new(:id)

  def setup
    Upkeep::Rails.configuration.clear_identities!
  end

  def teardown
    Upkeep::Rails.configuration.clear_identities!
  end

  def test_declared_session_identity_matches_request_and_connection
    Upkeep::Rails.configuration.identify :user, session: :user_id do
      subscribe { |cable| cable.request.session[:user_id] }
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

  def test_declared_cookie_identity_matches_request_and_connection
    Upkeep::Rails.configuration.identify :account, cookie: :account_id do
      subscribe { |cable| cable.request.cookies[:account_id] }
    end
    recorder = recorder_with(Upkeep::Dependencies::CookieValue.new(key: :account_id, value: "acct-1"))
    request_identity = identity.derive_from_request(nil, recorder: recorder)
    connection = FakeConnection.new(request: FakeRequest.new(session: {}, cookies: { account_id: "acct-1" }))
    subscription = subscription_for(request_identity, recorder, identity_names: ["account"])

    assert_equal request_identity.subscriber_id, identity.derive_for_subscription(connection, subscription).subscriber_id
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
