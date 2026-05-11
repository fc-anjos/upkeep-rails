# frozen_string_literal: true

require "test_helper"

class FeedBenchmarkSurfaceTest < ActionDispatch::IntegrationTest
  test "feed page exposes a shared turbo refresh stream" do
    FeedItem.create!(title: "One", body: "Body one")

    get "/feed"

    assert_response :success
    assert_includes @response.body, "signed-stream-name="
    assert_includes @response.body, "One"
    assert_includes @response.body, "Body one"
  end

  test "post feed creates a feed item" do
    assert_difference "FeedItem.count", 1 do
      post "/feed", params: { title: "Two", body: "Body two" }
    end

    assert_response :created
    assert_equal "Two", FeedItem.order(:id).last.title
  end
end
