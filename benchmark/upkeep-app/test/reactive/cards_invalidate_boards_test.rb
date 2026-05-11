# frozen_string_literal: true

require "test_helper"

# Exercises the full reactive chain: subscribe_to(board) → Card mutation via
# belongs_to touch: true → assert_invalidates fires + channel receives a frame.
class CardsInvalidateBoardsTest < ActiveSupport::TestCase
  setup do
    @user  = User.create!(name: "alice", email: "alice@example.com", password: "secret123")
    @board = Board.create!(name: "Kanban", creator: @user)
    @channel = subscribe_to(@board)
  end

  teardown do
    unsubscribe(@channel)
    Card.delete_all
    Board.delete_all
    User.delete_all
  end

  test "card create invalidates the parent board" do
    assert_invalidates(@board) do
      Card.create!(title: "First card", board: @board, creator: @user)
    end
  end

  test "card create on a different board does not invalidate this board" do
    other = Board.create!(name: "Other", creator: @user)
    refute_invalidates(@board) do
      Card.create!(title: "Other card", board: other, creator: @user)
    end
  ensure
    Card.delete_all
    other.destroy
  end
end
