# frozen_string_literal: true

require "test_helper"

class UpkeepJobRuntimeTest < ActiveJob::TestCase
  class RenameCardJob < ApplicationJob
    def perform(card)
      card.update!(title: "Updated by job")
    end
  end

  setup do
    Upkeep::Runtime::ChangeLog.reset
  end

  test "delivers committed Active Record changes" do
    user = User.create!(name: "Alice", email: "job@example.com", password: "secret123")
    board = Board.create!(name: "Planning", creator: user)
    card = Card.create!(board: board, creator: user, title: "Plan", status: "open")
    Upkeep::Runtime::ChangeLog.reset

    _result, facts = Upkeep::Rails::Testing.capture_change_facts do
      RenameCardJob.perform_now(card)
    end

    assert_equal "Updated by job", card.reload.title
    assert facts.any? { |fact| fact.fetch(:table) == "cards" && fact.fetch(:id) == card.id }
  end
end
