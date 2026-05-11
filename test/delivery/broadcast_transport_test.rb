# frozen_string_literal: true

require "test_helper"

class BroadcastTransportTest < Minitest::Test
  Envelope = Data.define(:subscriber_id, :body)
  Batch = Data.define(:envelopes)

  class RecordingAdapter
    attr_reader :delivered

    def initialize(failures: 0)
      @failures = failures
      @delivered = []
    end

    def deliver(envelope)
      raise "broadcast failed" if fail?

      delivered << [envelope.subscriber_id, envelope.body]
    end

    private

    def fail?
      return false if @failures.zero?

      @failures -= 1
      true
    end
  end

  def test_broadcasts_without_registered_connection_state
    adapter = RecordingAdapter.new
    transport = Upkeep::Delivery::BroadcastTransport.new(adapter: adapter)

    report = transport.deliver(batch_for("Alice" => "alice-stream", "Bob" => "bob-stream"))

    assert_equal({ delivered: 2 }, report.summary)
    assert_equal [["Alice", "alice-stream"], ["Bob", "bob-stream"]], adapter.delivered
    assert_equal 0, transport.summary.fetch(:adapter_overrides)
  end

  def test_retries_failed_broadcasts_with_bounded_queue
    adapter = RecordingAdapter.new(failures: 1)
    transport = Upkeep::Delivery::BroadcastTransport.new(adapter: adapter, max_queue_size: 1, retry_limit: 3)

    first_report = transport.deliver(batch_for("Alice" => "alice-stream"))
    retry_report = transport.retry_pending(subscriber_id: "Alice")

    assert_equal({ queued_retry: 1 }, first_report.summary)
    assert_equal({ delivered: 1 }, retry_report.summary)
    assert_equal [["Alice", "alice-stream"]], adapter.delivered
    assert_equal 0, transport.summary.fetch(:queued_envelopes)
  end

  def test_adapter_override_is_an_explicit_test_boundary
    default_adapter = RecordingAdapter.new
    override_adapter = RecordingAdapter.new
    transport = Upkeep::Delivery::BroadcastTransport.new(adapter: default_adapter)
    transport.connect(subscriber_id: "Alice", adapter: override_adapter)

    transport.deliver(batch_for("Alice" => "alice-stream", "Bob" => "bob-stream"))

    assert_equal [["Alice", "alice-stream"]], override_adapter.delivered
    assert_equal [["Bob", "bob-stream"]], default_adapter.delivered
  end

  private

  def batch_for(payloads)
    Batch.new(payloads.map { |subscriber_id, body| Envelope.new(subscriber_id, body) })
  end
end
