# frozen_string_literal: true

require "test_helper"
require "upkeep/relay/proof_subject"
require "upkeep/invalidate_time/proof_chain"

# Asserts the end-to-end wiring of the ivar code path that the
# `mixed_region_feed_ivar` benchmark fixture exercises through
# `GET /featured_item`: `view_assigns` extracted at request time must
# populate `fragment_slot_states` for ivar-rooted dynamic sources in
# the rendered partial, and the proof subject's `bindings` must carry
# the resolved AR column.
class FeaturedItemSlotStateTest < ActionDispatch::IntegrationTest
  setup do
    Upkeep.subscription_store.reset!
    FeedItem.delete_all
    User.delete_all

    @alice = User.create!(name: "Alice", email: "alice@example.com", password: "secret123")
    @item = FeedItem.create!(title: "Hello world", body: "First body")
  end

  teardown do
    Upkeep.subscription_store.reset!
    FeedItem.delete_all
    User.delete_all
  end

  test "featured_item populates fragment_slot_states with column-bound bindings for ivar dynamic sources" do
    payload = subscription_payload_for(@alice)
    subscription_id = payload.fetch("sub")

    slot_states = Upkeep.subscription_store.fragment_slot_states(subscription_id) || {}
    refute_empty slot_states, "expected fragment_slot_states for the featured_item page render"

    fragment_id = slot_states.keys.first
    assert fragment_id, "expected at least one fragment_id in slot_states"

    fragment_states = slot_states.fetch(fragment_id)
    title_slot = fragment_states.values.find { |slot| slot["column"] == "title" }
    body_slot  = fragment_states.values.find { |slot| slot["column"] == "body" }

    assert title_slot,
      "expected a slot with column=title in #{fragment_states.inspect} — view_assigns ivar resolution must produce column-bound bindings"
    assert_equal "feed_items", title_slot["table"]
    assert_equal "Hello world", title_slot["value"],
      "expected canonical rendered title bytes captured at first render"

    assert body_slot,
      "expected a slot with column=body in #{fragment_states.inspect}"
    assert_equal "First body", body_slot["value"]
  end

  test "featured_item proof chain proves byte equality on a title update" do
    payload = subscription_payload_for(@alice)
    subscription_id = payload.fetch("sub")

    snapshot = Upkeep.subscription_store.fetch_for_relay(subscription_id)
    assert snapshot, "expected a relay snapshot for #{subscription_id}"

    proof_subject = Upkeep::Relay::ProofSubject.new(snapshot)

    context = Upkeep::InvalidateTime::ProofChain::Context.new(
      subscription: proof_subject,
      payload: {
        "table" => "feed_items",
        "event" => "update",
        "attributes" => { "id" => @item.id },
        "changes" => { "title" => [ "Hello world", "Hello world updated" ] },
        "operation_id" => "test-op-1"
      }
    )

    verdict = Upkeep::InvalidateTime::ProofChain.run(context)

    assert_equal :proven, verdict.outcome,
      "expected the byte_equality gate to prove a title-only update; got #{verdict.outcome.inspect}/#{verdict.reason.inspect}"
    assert_equal :byte_equality, verdict.reason
    refute_nil verdict.payload, "expected patches in verdict payload"
    refute_empty verdict.payload[:patches], "expected non-empty patches"
  end

  test "featured_item manifest classifies the title and body region slots as stable_direct_push" do
    payload = subscription_payload_for(@alice)
    subscription_id = payload.fetch("sub")

    slot_states = Upkeep.subscription_store.fragment_slot_states(subscription_id) || {}
    fragment_id = slot_states.keys.first
    assert fragment_id, "expected a fragment_id"

    manifest = Upkeep::CompileTime::Manifest::Registry.lookup(
      Upkeep::State::FragmentIdentity.manifest_key(fragment_id)
    )
    assert manifest, "expected manifest for #{fragment_id}"

    stable_regions = manifest.regions.select(&:stable_direct_push?)
    assert stable_regions.any?,
      "expected at least one stable_direct_push region in #{manifest.regions.map(&:diagnostics).inspect} — " \
      "the title and body slots read AR columns through ivars and should classify as :none / :request_free"
  end

  private

  def subscription_payload_for(user)
    session = open_session
    session.post "/sessions",
      params: { email: user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    session.assert_response :success

    session.get "/featured_item"
    session.assert_response :success

    token = session.response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "expected context token in featured_item response"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "expected featured_item context token to verify"
    payload
  end
end
