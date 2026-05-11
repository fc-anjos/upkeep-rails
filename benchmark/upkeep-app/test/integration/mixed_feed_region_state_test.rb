# frozen_string_literal: true

require "test_helper"

class MixedFeedRegionStateTest < ActionDispatch::IntegrationTest
  setup do
    Upkeep.subscription_store.reset!
    FeedItem.delete_all
    User.delete_all

    @alice = User.create!(name: "Alice", email: "alice@example.com", password: "secret123")
    @bob = User.create!(name: "Bob", email: "bob@example.com", password: "secret123")
    @item = FeedItem.create!(title: "Shared title", body: "Shared body")
  end

  teardown do
    Upkeep.subscription_store.reset!
    FeedItem.delete_all
    User.delete_all
  end

  test "mixed feed keeps stable row region digest shared while current-user region digest diverges" do
    alice_payload = subscription_payload_for(@alice)
    bob_payload = subscription_payload_for(@bob)

    refute_equal alice_payload.fetch("sub"), bob_payload.fetch("sub"),
      "mixed feed subscribers with different Current.user state need distinct subscription identities"

    alice_regions = region_digests_for(alice_payload.fetch("sub"))
    bob_regions = region_digests_for(bob_payload.fetch("sub"))

    fragment_id = alice_regions.keys.find { |candidate| candidate.start_with?("feed_item_") }
    assert fragment_id, "expected feed item region digests in #{alice_regions.inspect}"

    manifest = Upkeep::CompileTime::Manifest::Registry.lookup(
      Upkeep::State::FragmentIdentity.manifest_key(fragment_id)
    )
    assert manifest, "expected mixed feed item manifest for #{fragment_id}"

    stable_region = manifest.regions.find { |region| region.diagnostics.include?("proof:stable_direct_push") }
    current_region = manifest.regions.find { |region| region.dependency_vector.include?(:current) }
    transient_region = manifest.regions.find { |region| region.fallback_reasons.any? { |reason| reason.start_with?("transient_local:") } }

    assert stable_region, "expected a stable direct-push region in #{manifest.regions.map(&:diagnostics).inspect}"
    assert current_region, "expected a current-user region in #{manifest.regions.map(&:dependency_vector).inspect}"
    assert transient_region, "expected a transient controller-hydrated region in #{manifest.regions.map(&:fallback_reasons).inspect}"

    assert_equal alice_regions.fetch(fragment_id).fetch(stable_region.id),
      bob_regions.fetch(fragment_id).fetch(stable_region.id)
    refute_equal alice_regions.fetch(fragment_id).fetch(current_region.id),
      bob_regions.fetch(fragment_id).fetch(current_region.id)
  end

  private

  def subscription_payload_for(user)
    session = open_session
    session.post "/sessions",
      params: { email: user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    session.assert_response :success

    session.get "/mixed_feed"
    session.assert_response :success

    token = session.response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "expected context token in mixed feed response"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "expected mixed feed context token to verify"
    payload
  end

  def region_digests_for(subscription_id)
    Upkeep.subscription_store.fragment_region_digests(subscription_id) || {}
  end
end
