# frozen_string_literal: true

require "test_helper"

class LobstersSurfaceTest < ActionDispatch::IntegrationTest
  setup do
    LobstersSeedData.call
    @story = seeded_story
    @user = seeded_user
  end

  test "renders index and story discussion pages" do
    get "/"
    assert_response :success
    assert_select "ol.stories li.story", minimum: 1

    get @story.comments_path
    assert_response :success
    assert_select "textarea[name=comment]"
  end

  test "creates comments and records votes through Lobsters controllers" do
    sign_in_as @user

    assert_difference -> { Comment.count }, 1 do
      post "/comments", params: {
        story_id: @story.short_id,
        comment: "Benchmark smoke comment"
      }, headers: XHR_HEADERS
    end
    assert_response :success
    assert_includes response.body, "Benchmark smoke comment"

    assert_difference -> { Vote.where(user: @user, story: @story, comment_id: nil).count }, 1 do
      post "/stories/#{@story.short_id}/upvote"
    end
    assert_response :success
    assert_equal "ok", response.body
  end
end
