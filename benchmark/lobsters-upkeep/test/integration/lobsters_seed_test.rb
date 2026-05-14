# frozen_string_literal: true

require "test_helper"

class LobstersSeedTest < ActiveSupport::TestCase
  test "seed data creates benchmark identities and discussion data" do
    LobstersSeedData.call

    assert User.find_by(email: "user1@bench.test")
    assert_operator Story.count, :>=, 1
    assert_operator Comment.count, :>=, 1
    assert_operator Vote.count, :>=, 1
  end
end
