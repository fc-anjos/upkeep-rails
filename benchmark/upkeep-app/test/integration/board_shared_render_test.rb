# frozen_string_literal: true

require "test_helper"

class BoardSharedRenderTest < ActionDispatch::IntegrationTest
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

  test "board card markup is identical across viewers" do
    assert_equal cards_markup_for(@users.first), cards_markup_for(@users.second)
  end

  private

  def cards_markup_for(user)
    post "/sessions", params: { email: user.email, password: "secret123" }
    get "/boards/#{@board.id}"
    assert_response :success

    response.body[/<div id="cards">\s*(.*?)\s*<\/div>/m, 1]
  end
end
