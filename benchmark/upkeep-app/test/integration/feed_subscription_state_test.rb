# frozen_string_literal: true

require "test_helper"

class FeedSubscriptionStateTest < ActionDispatch::IntegrationTest
  setup do
    FeedItem.delete_all
    FeedItem.create!(title: "One", body: "Body one")
    FeedItem.create!(title: "Two", body: "Body two")
  end

  teardown do
    FeedItem.delete_all
  end

  test "GET /feed persists fragment hashes for subscribed feed items" do
    get "/feed"
    assert_response :success

    token = response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "expected context token in feed response"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "expected signed context token to verify"

    fragment_hashes = Upkeep.subscription_store.fragment_hashes(payload["sub"])
    assert fragment_hashes.present?, "expected fragment hashes for feed subscription"

    feed_item_fragments = fragment_hashes.select { |fragment_id, _| fragment_id.start_with?("feed_item_") }
    assert feed_item_fragments.any?, "expected feed item fragments in #{fragment_hashes.inspect}"
    assert feed_item_fragments.values.all?(&:present?), "expected all feed item fragments to carry compile-time hashes"

    manifests = feed_item_fragments.transform_values do |fragment_hash|
      Upkeep::CompileTime::Manifest::Registry.lookup(fragment_hash)
    end
    assert manifests.values.all?,
      "expected manifest entries for feed item fragment hashes, got #{manifests.transform_values { |m| manifest_mode(m) }.inspect}"

    dispatch_state = Upkeep.subscription_store.fetch_for_relay(payload["sub"])
    assert dispatch_state.present?, "expected dispatch-safe subscription state"

    dispatch_feed_fragments = dispatch_state.fragment_locals_digests.keys.grep(/\Afeed_item_/)
    assert dispatch_feed_fragments.any?,
      "expected feed item digests in #{dispatch_state.fragment_locals_digests.inspect}"

    relay_feed_modes = dispatch_state.fragment_render_modes.slice(*dispatch_feed_fragments)
    assert_equal [ "request_free" ], relay_feed_modes.values.uniq.sort,
      "expected request_free modes for #{dispatch_feed_fragments.inspect}, got modes=#{dispatch_state.fragment_render_modes.inspect}"

    relay_feed_tiers = dispatch_state.fragment_identity_tiers.slice(*dispatch_feed_fragments)
    assert_equal [ "none" ], relay_feed_tiers.values.uniq.sort,
      "expected none tiers for #{dispatch_feed_fragments.inspect}, got tiers=#{dispatch_state.fragment_identity_tiers.inspect}"
  end

  private

  def manifest_mode(manifest)
    return nil unless manifest

    Upkeep::RenderMode.project(Array(manifest.render_mode_reasons))
  end
end
