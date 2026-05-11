# frozen_string_literal: true

require "test_helper"

class AsyncDispatcherTest < Minitest::Test
  def test_dispatches_each_enqueued_change_set_as_a_distinct_job
    delivered = Queue.new
    dispatcher = Upkeep::Delivery::AsyncDispatcher.new do |changes|
      delivered << changes
    end

    dispatcher.enqueue([{ table: "messages", id: 1 }])
    dispatcher.enqueue([{ table: "messages", id: 2 }])
    dispatcher.drain

    assert_equal [[{ table: "messages", id: 1 }], [{ table: "messages", id: 2 }]], [delivered.pop, delivered.pop]
  ensure
    dispatcher&.shutdown
  end
end
