# frozen_string_literal: true

require "test_helper"

class RoomRealtimeDeliveryTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(name: "alice", email: "alice@example.com", password: "secret123")
    @room = Room.create!(name: "General")
    @room.messages.create!(body: "hello", user: @user)
  end

  teardown do
    Message.delete_all
    Room.delete_all
    User.delete_all
  end

  test "posting a room message publishes an invalidation for the shared room surface" do
    post "/sessions",
      params: { email: @user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    first = subscription_payload_for("/rooms/#{@room.id}")
    second = subscription_payload_for("/rooms/#{@room.id}")

    assert_equal first["sub"], second["sub"],
      "same-user room reloads must join the same subscription identity before a write can fan out to sibling endpoints"

    events = []
    subscription = ActiveSupport::Notifications.subscribe("upkeep.invalidation") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    begin
      post "/rooms/#{@room.id}/messages",
        params: { message: { body: "from tab a" } },
        headers: { "X-Upkeep-Operation-Id" => SecureRandom.uuid }
      assert_response :created
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    room_events = events.select do |event|
      event.payload[:table] == "messages" && event.payload[:event] == :create
    end

    assert room_events.any?,
      "expected a messages create invalidation for the room surface; got #{events.map { |e| e.payload.inspect }.inspect}"
  end

  private

  def subscription_payload_for(path)
    get path
    assert_response :success

    token = response.body[/data-context-token="([^"]+)"/, 1]
    assert token, "expected context token in #{path}"

    payload = Upkeep::SubscribeTime::Subscription::StreamName.verified_context_token(token)
    assert payload, "expected context token in #{path} to verify"
    payload
  end
end
