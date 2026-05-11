# frozen_string_literal: true

require "test_helper"

# Reproduces the k6 failure: GET /boards/:id for an authenticated user must
# return HTML containing a `data-context-token="..."` attribute injected by
# PageRequest.
class BoardTokenInjectionTest < ActionDispatch::IntegrationTest
  setup do
    @user  = User.create!(name: "alice", email: "alice@example.com", password: "secret123")
    @board = Board.create!(name: "Kanban", creator: @user)
    Access.create!(board: @board, user: @user)
  end

  teardown do
    Access.delete_all
    Board.delete_all
    User.delete_all
  end

  test "authenticated board show renders data-context-token (HTML login)" do
    post "/sessions", params: { email: @user.email, password: "secret123" }
    assert_response :redirect

    get "/boards/#{@board.id}"
    assert_response :success
    assert_match(/data-context-token="[^"]+"/, response.body)
  end

  # Mirrors k6's auth.js exactly: JSON POST to /sessions, then GET the page.
  test "authenticated board show renders data-context-token (JSON login, k6 flow)" do
    post "/sessions",
      params: { email: @user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success, "JSON login must return 200; got #{response.status} body=#{response.body[0, 200]}"

    get "/boards/#{@board.id}"
    assert_response :success,
      "GET /boards/:id must be 200; got #{response.status} location=#{response.headers["Location"]} body=#{response.body[0, 200]}"
    assert_match(/data-context-token="[^"]+"/, response.body,
      "Expected token; body-tail=#{response.body[-400..]}")
  end

  test "same-user repeated board loads reuse subscription identity but mint a fresh endpoint" do
    post "/sessions",
      params: { email: @user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success

    first = subscription_payload_for("/boards/#{@board.id}")
    second = subscription_payload_for("/boards/#{@board.id}")

    assert_equal first["sub"], second["sub"],
      "same-user board reloads should join the same subscription identity"
    refute_equal first["ep"], second["ep"]
  end

  test "board subscriptions stay user-keyed across viewers" do
    post "/sessions",
      params: { email: @user.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success
    first = subscription_payload_for("/boards/#{@board.id}")
    delete "/session"

    other = User.create!(name: "bob", email: "bob@example.com", password: "secret123")
    Access.create!(board: @board, user: other)

    post "/sessions",
      params: { email: other.email, password: "secret123" }.to_json,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
    assert_response :success
    second = subscription_payload_for("/boards/#{@board.id}")

    refute_equal first["sub"], second["sub"],
      "board benchmark surface is user-keyed and must not be treated as a shared audience across viewers"
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
