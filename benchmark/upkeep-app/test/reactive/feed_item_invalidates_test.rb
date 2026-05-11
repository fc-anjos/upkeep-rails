# frozen_string_literal: true

require "test_helper"

class FeedItemInvalidatesTest < ActionDispatch::IntegrationTest
  include Upkeep::Testing::Assertions

  test "POST /feed records a dispatch invalidation event" do
    Upkeep::Runtime::RelayRuntime.reset!
    Upkeep::Runtime::RelayRuntime.configure_for_test!

    post "/feed", params: { title: "x", body: "y" }
    assert_response :created

    events = Upkeep::Runtime::RelayRuntime.recorded_events || []
    feed_msgs = events.select { |message| message.fetch("table") == "feed_items" }
    assert feed_msgs.any?,
      "expected dispatch invalidation event for feed_items; got #{events.size} events: #{events.map(&:inspect).inspect}"
  ensure
    Upkeep::Runtime::RelayRuntime.reset!
  end

  test "POST /feed dispatches an upkeep.invalidation event" do
    events = []
    sub = ActiveSupport::Notifications.subscribe("upkeep.invalidation") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    begin
      post "/feed", params: { title: "x", body: "y" }
      assert_response :created
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    feed_events = events.select { |e| e.payload[:table] == "feed_items" }
    assert feed_events.any?,
      "expected upkeep.invalidation for feed_items; got: #{events.map { |e| e.payload.inspect }.inspect}"
  end
end
