# frozen_string_literal: true

require "test_helper"
require "upkeep/relay/result_hash_map"
require "upkeep/relay/render_group_coordinator"

# Runtime probe for the observation-eligibility-truth spike.
#
# Question: the Lobsters story_comments smoke gate reports 0 region-scoped
# delivery groups, but static analysis (spikes/observation-eligibility-truth/
# c1_correctness.rb + layer_diagnostic.rb) found the hot-path partials
# produce 52 S-eligible regions and 44 upkeep_region_scope calls in their
# rewritten ERB. So the chain breaks somewhere between L4 (rewritten AST
# has region helper calls) and L8 (relay coordinator forms region groups).
#
# This probe exercises the registration path end-to-end, then dumps the
# post-registration state from the SubscriptionStore. Layers checked:
#
#   L5 — runtime executes upkeep_region_scope blocks
#         → session.per_region_inputs / session.per_region_outputs populated
#   L6 — Registrar reads them and computes digests
#   L7 — Snapshot read by relay carries fragment_region_digests +
#         fragment_region_output_digests
#
# If both digest fields are non-empty after the GET, the chain passes
# L5–L7 and the failure is at L8–L10 (relay-side: coordinator's
# register_regions / classify_regions). If empty, the failure is at L5
# or L6 — observation didn't fire or the registrar didn't compute.

class RegionDigestProbeTest < ActionDispatch::IntegrationTest
  setup do
    LobstersSeedData.call
    @story = seeded_story
    @user = seeded_user
    sign_in_as @user
  end

  test "PROBE: post-registration state contains fragment_region_digests" do
    get @story.comments_path
    assert_response :success

    token = response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "context token missing — registration didn't happen"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "context token failed verification"

    subscription_id = payload["sub"]
    state = Upkeep::Runtime.subscription_store.fetch_for_relay(subscription_id)
    assert state, "subscription_store.fetch_for_relay(#{subscription_id.inspect}) returned nil"

    # Dump the digest landscape so the failure mode is unambiguous.
    fr_digests = state.fragment_region_digests || {}
    fr_output_digests = state.fragment_region_output_digests || {}
    fragment_locals_digests = state.fragment_locals_digests || {}

    diag = +<<~DIAG
      \n=== Region digest probe — post-GET subscription state ===
      subscription_id: #{subscription_id}
      url: #{state.subscription_url}
      fragment count (locals_digests):     #{fragment_locals_digests.size}
      fragment count (region_input):       #{fr_digests.size}
      fragment count (region_output):      #{fr_output_digests.size}
      sum regions across fragments (in):   #{fr_digests.values.sum { |h| (h || {}).size }}
      sum regions across fragments (out):  #{fr_output_digests.values.sum { |h| (h || {}).size }}
      sample fragment_ids:                 #{fragment_locals_digests.keys.first(5).inspect}
      sample fragment_ids (region in):     #{fr_digests.keys.first(5).inspect}
    DIAG

    fr_digests.first(3).each do |frag_id, regions|
      diag << "  region_input  fragment_id=#{frag_id} regions=#{(regions || {}).keys.first(5).inspect}\n"
    end
    fr_output_digests.first(3).each do |frag_id, regions|
      diag << "  region_output fragment_id=#{frag_id} regions=#{(regions || {}).keys.first(5).inspect}\n"
    end

    puts diag

    assert_equal fr_digests.empty?, fr_output_digests.empty?,
      "input/output digest population should be coherent (one without the other is a bug)"

    assert fragment_locals_digests.any?,
      "no fragments registered at all — middleware didn't run or no fragments classified"

    refute fr_digests.empty?,
      "fragment_region_digests EMPTY — chain breaks at L5 or L6 " \
      "(observation didn't fire on registration render, OR registrar " \
      "didn't compute digests from per_region_inputs)\n#{diag}"

    # ---------- L8: feed the live snapshot to a fresh ResultHashMap ----------
    # ResultHashMap.register(snapshot) is what the relay calls on every
    # subscription change. It calls register_regions(snapshot) which walks
    # fragment_region_digests and indexes one bucket per region under
    # region_key(url, fragment_id, region_id, region_digest). If that bucket
    # ever has members, the coordinator can form region-scoped groups.

    # ResultGroupIndex is the inner index that owns the region-keyed
    # buckets. ResultHashMap composes it but its registration runs
    # inside Async::Semaphore; we use the inner index directly to
    # sidestep needing an Async reactor in this probe.
    groups_index = Upkeep::Relay::ResultGroupIndex.new
    groups_index.register(state)

    groups_table = groups_index.instance_variable_get(:@groups)
    region_keys = groups_table.keys.select { |k| k.is_a?(Array) && k.first == :region }
    fragment_keys = groups_table.keys.reject { |k| k.is_a?(Array) && k.first == :region }

    puts <<~L8
      \n=== L8: ResultHashMap indexing ===
      total bucket keys:           #{groups_table.size}
      fragment-scoped buckets:     #{fragment_keys.size}
      region-scoped buckets:       #{region_keys.size}
      sample fragment-scoped key:  #{fragment_keys.first.inspect}
      sample region-scoped key:    #{region_keys.first.inspect}
    L8

    refute region_keys.empty?,
      "ResultHashMap.register did not produce any region-scoped buckets " \
      "even though the snapshot has #{fr_digests.values.sum { |h| (h || {}).size }} regions. " \
      "Chain breaks at L8 — register_regions is not indexing the snapshot."

    # ---------- L9: drive RenderGroupCoordinator and see what classify_regions returns ----------
    # Build a minimal coordinator and ask it to classify the snapshot's
    # first fragment's regions. If `classify_regions` returns
    # `eligible: {}, ineligible: {...all...}`, the coordinator's gate is
    # filtering them out — surface which gate. If it returns eligible
    # entries, L9 passes and the failure is at L10 (GroupExecutor).
    coordinator_class = Upkeep::Relay::RenderGroupCoordinator
    coordinator = coordinator_class.allocate
    sample_frag, sample_regions = fr_digests.first
    eligible, ineligible = coordinator.send(:classify_regions, sample_frag, sample_regions)

    puts <<~L9
      \n=== L9: classify_regions output for first fragment ===
      fragment_id:           #{sample_frag}
      input region_digests:  #{sample_regions.size}
      eligible:              #{eligible.size}
      ineligible:            #{ineligible.size}
      sample eligible keys:   #{eligible.keys.first(5).inspect}
      sample ineligible keys: #{ineligible.keys.first(5).inspect}
    L9

    refute eligible.empty?,
      "classify_regions returned 0 eligible regions for #{sample_frag} " \
      "even though static analysis shows hot-path partials produce S-eligible regions. " \
      "Chain breaks at L9 — coordinator's eligibility gate filters all #{sample_regions.size} regions out."
  end
end
