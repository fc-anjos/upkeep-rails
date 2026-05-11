# frozen_string_literal: true

require "test_helper"

class BenchRequestInstrumentationTest < ActionDispatch::IntegrationTest
  setup do
    @previous_bench = ENV["BENCH"]
    ENV["BENCH"] = "1"
    @user = User.create!(name: "alice", email: "alice@example.com", password: "secret123")
    @room = Room.create!(name: "General")
  end

  teardown do
    Room.delete_all
    User.delete_all
    ENV["BENCH"] = @previous_bench
  end

  test "session create and room show emit correlated bench request notifications" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("bench.request") { |event| events << event }

    post "/sessions",
      params: { email: @user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success
    login_request_id = response.headers["X-Bench-Request-Id"]
    assert login_request_id.present?

    get "/rooms/#{@room.id}"
    assert_response :success
    room_request_id = response.headers["X-Bench-Request-Id"]
    assert room_request_id.present?

    login_event = events.find { |event| event.payload[:phase] == "sessions#create" }
    room_event = events.find { |event| event.payload[:phase] == "rooms#show" }

    assert_equal login_request_id, login_event&.payload&.dig(:request_id)
    assert_equal room_request_id, room_event&.payload&.dig(:request_id)
    assert_equal "/rooms/#{@room.id}", room_event&.payload&.dig(:path)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end
end
