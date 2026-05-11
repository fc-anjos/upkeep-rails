# frozen_string_literal: true

require "test_helper"
require "action_cable/test_helper"

class BenchmarkSurfaceTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  PASSWORD = "secret123"

  setup do
    Upkeep::Rails.reset_runtime!

    @alice = create_user("Alice", "alice@example.com")
    @bob = create_user("Bob", "bob@example.com")

    @room = Room.create!(name: "General")
    RoomMembership.create!(room: @room, user: @alice)
    Message.create!(room: @room, user: @alice, body: "Hello from the room")

    @board = Board.create!(name: "Launch Board", creator: @alice)
    Access.create!(board: @board, user: @alice)
    @card = Card.create!(board: @board, creator: @alice, title: "Wire graph capture")
    Comment.create!(card: @card, body: "Captured through a helper render")

    @private_board = Board.create!(name: "Private Board", creator: @bob)
    Access.create!(board: @private_board, user: @bob)
    Card.create!(board: @private_board, creator: @bob, title: "Hidden card value")

    FeedItem.create!(title: "Shared feed item", body: "Public benchmark row")
    Upkeep::Runtime::ChangeLog.reset
  end

  test "renders authenticated board and room surfaces" do
    sign_in(@alice)

    get board_path(@board)
    assert_response :success
    assert_select "h1", "Launch Board"
    assert_select "#cards", text: /Wire graph capture/

    get room_path(@room)
    assert_response :success
    assert_select "h1", "General"
    assert_select "#messages", text: /Hello from the room/
  end

  test "keeps unauthorized board bytes out of the response" do
    sign_in(@alice)

    get board_path(@private_board)
    assert_response :forbidden
    refute_includes response.body, "Hidden card value"
  end

  test "renders shared feed and helper-hidden render idioms" do
    get feed_path
    assert_response :success
    assert_select "#feed_items", text: /Shared feed item/

    get m3_helper_hidden_collection_path(@card)
    assert_response :success
    assert_select "#m3-helper-hidden", text: /Captured through a helper render/
  end

  test "delivers a streamed update through the derived subscriber stream" do
    sign_in(@alice)

    get board_path(@board)
    assert_response :success
    assert_instance_of Upkeep::Subscriptions::ActiveRecordStore, Upkeep::Rails.subscriptions
    subscription = Upkeep::Rails.subscriptions.subscriptions.first
    assert subscription
    assert_select "script[data-upkeep-subscription]"

    stream_names = ([subscription.metadata.fetch(:stream_name)] + subscription.metadata.fetch(:shared_stream_names, [])).uniq
    broadcasts = capture_broadcasts_for(stream_names) do
      patch board_card_path(@board, @card), params: { card: { title: "Streamed graph capture" } }
      assert_response :ok
      Upkeep::Rails.drain_delivery!
    end

    assert_equal 1, broadcasts.size
    assert_includes broadcasts.first, "Streamed graph capture"
    refute_includes broadcasts.first, "Hidden card value"
  end

  private

  def create_user(name, email)
    User.create!(name: name, email: email, password: PASSWORD)
  end

  def sign_in(user)
    post "/sessions", params: { email: user.email, password: PASSWORD }, as: :json
    assert_response :success
  end

  def capture_broadcasts_for(stream_names, &mutation)
    captures = {}
    nested = stream_names.reverse_each.reduce(mutation) do |inner, stream_name|
      proc { captures[stream_name] = capture_broadcasts(stream_name, &inner) }
    end

    nested.call
    captures.values.flatten
  end
end
