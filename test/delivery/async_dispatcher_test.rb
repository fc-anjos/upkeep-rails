# frozen_string_literal: true

require "test_helper"

class AsyncDispatcherTest < Minitest::Test
  def test_dispatches_enqueued_change_sets_as_a_burst_batch
    delivered = Queue.new
    dispatcher = Upkeep::Delivery::AsyncDispatcher.new(batch_window: 0.05) do |change_sets|
      delivered << change_sets
    end

    dispatcher.enqueue([{ table: "messages", id: 1 }])
    dispatcher.enqueue([{ table: "messages", id: 2 }])
    dispatcher.drain

    assert_equal [[{ table: "messages", id: 1 }], [{ table: "messages", id: 2 }]], delivered.pop
  ensure
    dispatcher&.shutdown
  end
end
