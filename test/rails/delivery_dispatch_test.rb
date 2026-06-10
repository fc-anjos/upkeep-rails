# frozen_string_literal: true

require "test_helper"

class DeliveryDispatchTest < Minitest::Test
  def setup
    @previous_inline = Upkeep::Rails.configuration.deliver_inline
  end

  def teardown
    Upkeep::Rails.configuration.deliver_inline = @previous_inline
    Upkeep::Rails.reset_runtime!
  end

  def test_deliver_inline_defaults_to_false
    assert_equal false, Upkeep::Rails::Configuration.new.deliver_inline
  end

  def test_dispatch_runs_on_the_in_process_dispatcher_by_default
    Upkeep::Rails.configuration.deliver_inline = false
    transport = RecordingDispatchTransport.new
    Upkeep::Rails.instance_variable_set(:@transport, transport)
    events = capture_enqueue_events do
      report = Upkeep::Rails.deliver_changes!([delivery_change])
      Upkeep::Rails::Testing.drain_delivery!

      assert_instance_of Upkeep::Delivery::Transport::DispatchReport, report
    end

    assert_equal 1, events.size
    assert_equal false, events.first.payload.fetch(:inline)
    assert_equal 1, events.first.payload.fetch(:change_count)
    refute_includes transport.threads, Thread.current
  end

  def test_inline_mode_delivers_in_the_caller
    Upkeep::Rails.configuration.deliver_inline = true
    transport = RecordingDispatchTransport.new
    Upkeep::Rails.instance_variable_set(:@transport, transport)
    events = capture_enqueue_events do
      Upkeep::Rails.deliver_changes!([delivery_change])
    end

    assert_equal 1, events.size
    assert_equal true, events.first.payload.fetch(:inline)
    assert_equal [Thread.current], transport.threads
  end

  def test_dispatch_failure_is_instrumented_and_does_not_raise
    Upkeep::Rails.configuration.deliver_inline = true
    Upkeep::Rails.instance_variable_set(:@transport, FailingDispatchTransport.new)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(Upkeep::Rails::DELIVERY_ENQUEUE_ERROR) do |event|
      events << event
    end

    report = Upkeep::Rails.deliver_changes!([delivery_change])

    assert_instance_of Upkeep::Delivery::Transport::DispatchReport, report
    assert_equal 1, events.size
    assert_equal true, events.first.payload.fetch(:inline)
    assert_equal "RuntimeError", events.first.payload.fetch(:error_class)
    assert_equal "transport down", events.first.payload.fetch(:error_message)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  private

  def capture_enqueue_events
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(Upkeep::Rails::DELIVERY_ENQUEUE) do |event|
      events << event
    end

    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def delivery_change
    {
      type: "update",
      table: "cards",
      model: "Card",
      id: 1,
      changed_attributes: ["title"],
      old_values: { "title" => "Plan" },
      new_values: { "title" => "Plan v2" }
    }
  end
end

class RecordingDispatchTransport
  attr_reader :threads

  def initialize
    @threads = []
  end

  def deliver(_batch)
    @threads << Thread.current
    Upkeep::Delivery::Transport::DispatchReport.new([])
  end
end

class FailingDispatchTransport
  def deliver(_batch)
    raise "transport down"
  end
end
