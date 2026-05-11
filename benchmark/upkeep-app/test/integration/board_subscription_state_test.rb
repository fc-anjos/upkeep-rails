# frozen_string_literal: true

require "test_helper"

class BoardSubscriptionStateTest < ActionDispatch::IntegrationTest
  setup do
    @users = Array.new(2) do |i|
      User.create!(
        name: "user-#{i + 1}",
        email: "user-#{i + 1}@example.test",
        password: "secret123"
      )
    end
    @board = Board.create!(name: "Shared board", creator: @users.first)
    @users.each { |user| Access.create!(board: @board, user: user) }
    3.times do |i|
      Card.create!(
        title: "Card #{i + 1}",
        status: %w[todo in_progress done][i],
        board: @board,
        creator: @users[i % @users.length]
      )
    end
  end

  teardown do
    Access.delete_all
    Card.delete_all
    Board.delete_all
    User.delete_all
  end

  test "board card fragments stay shared across viewers even though the page is user-keyed" do
    first = board_fragment_state_for(@users.first)
    second = board_fragment_state_for(@users.second)

    refute_equal first[:payload]["sub"], second[:payload]["sub"],
      "board page subscriptions should stay distinct across viewers"

    assert_equal first[:fragment_hashes], second[:fragment_hashes],
      "card fragment ids and hashes should match across viewers"
    assert_equal first[:fragment_digests], second[:fragment_digests],
      "card fragment dedup digests should match across viewers"

    [ first[:dispatch_state], second[:dispatch_state] ].each do |dispatch_state|
      card_modes = dispatch_state.fragment_render_modes.slice(*first[:fragment_digests].keys)
      assert_equal [ "request_free" ], card_modes.values.uniq.sort,
        "expected request_free card fragments, got #{card_modes.inspect}"

      card_tiers = dispatch_state.fragment_identity_tiers.slice(*first[:fragment_digests].keys)
      assert_equal [ "none" ], card_tiers.values.uniq.sort,
        "expected none-tier card fragments, got #{card_tiers.inspect}"
    end
  end

  private

  def board_fragment_state_for(user)
    post "/sessions",
      params: { email: user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    get "/boards/#{@board.id}"
    assert_response :success

    token = response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "expected context token in board response"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "expected signed context token to verify"

    fragment_hashes = Upkeep.subscription_store.fragment_hashes(payload["sub"])
    assert fragment_hashes.present?, "expected fragment hashes for board subscription"

    card_fragments = fragment_hashes.select { |fragment_id, _| fragment_id.start_with?("card_") }
    assert card_fragments.any?, "expected card fragments in #{fragment_hashes.inspect}"
    assert card_fragments.values.all?(&:present?),
      "expected card fragments to carry compile-time hashes"

    manifests = card_fragments.transform_values do |fragment_hash|
      Upkeep::CompileTime::Manifest::Registry.lookup(fragment_hash)
    end
    assert manifests.values.all?,
      "expected manifest entries for #{card_fragments.inspect}, got #{manifests.transform_values(&:inspect)}"

    dispatch_state = Upkeep.subscription_store.fetch_for_relay(payload["sub"])
    assert dispatch_state.present?, "expected dispatch-safe subscription state"

    fragment_digests = dispatch_state.fragment_locals_digests.select { |fragment_id, _| fragment_id.start_with?("card_") }
    assert fragment_digests.any?,
      "expected card fragment digests in #{dispatch_state.fragment_locals_digests.inspect}"

    delete "/session"

    {
      payload: payload,
      fragment_hashes: card_fragments,
      fragment_digests: fragment_digests,
      dispatch_state: dispatch_state
    }
  end
end
