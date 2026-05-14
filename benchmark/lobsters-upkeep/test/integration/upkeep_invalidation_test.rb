# frozen_string_literal: true

require "test_helper"

class UpkeepInvalidationTest < ActionDispatch::IntegrationTest
  setup do
    LobstersSeedData.call
    @story = seeded_story
    @user = seeded_user
    sign_in_as @user
  end

  test "comment create emits an upkeep invalidation" do
    events = []
    subscription = ActiveSupport::Notifications.subscribe("upkeep.invalidation") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end

    post "/comments", params: {
      story_id: @story.short_id,
      comment: "upkeep invalidation marker"
    }
    assert_response :redirect
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
    assert events.any? { |event| event.payload[:table] == "comments" },
      "expected comments invalidation, got #{events.map(&:payload).inspect}"
  end
end
