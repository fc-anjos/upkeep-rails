# frozen_string_literal: true

require "test_helper"

class TransportDeliveryTest < Minitest::Test
  Envelope = Data.define(:subscriber_id, :body) do
    def report
      { subscriber_id: subscriber_id, body: body }
    end
  end

  Batch = Data.define(:envelopes)

  class RecordingAdapter
    attr_reader :bodies

    def initialize(failures: 0)
      @failures = failures
      @bodies = []
    end

    def deliver(envelope)
      raise "delivery failed" if fail?

      bodies << envelope.body
    end

    private

    def fail?
      return false if @failures.zero?

      @failures -= 1
      true
    end
  end

  def test_delivers_only_to_connected_subscribers
    alice = RecordingAdapter.new
    transport = Upkeep::Delivery::Transport.new
    transport.connect(subscriber_id: "Alice", adapter: alice)

    report = transport.deliver(batch_for("Alice" => "alice-stream", "Bob" => "bob-stream"))

    assert_equal({ delivered: 1, disconnected: 1 }, report.summary)
    assert_equal ["alice-stream"], alice.bodies
    assert_equal [], outcomes_with(report, :disconnected).select { |outcome| outcome.subscriber_id == "Alice" }
    assert_equal ["Bob"], outcomes_with(report, :disconnected).map(&:subscriber_id)
  end

  def test_disconnect_cleans_pending_retry_work
    adapter = RecordingAdapter.new(failures: 1)
    transport = Upkeep::Delivery::Transport.new(max_queue_size: 2, retry_limit: 3)
    transport.connect(subscriber_id: "Alice", adapter: adapter)

    report = transport.deliver(batch_for("Alice" => "alice-stream"))

    assert_equal({ queued_retry: 1 }, report.summary)
    assert_equal 1, transport.summary.fetch(:queued_envelopes)

    cleanup = transport.disconnect("Alice")

    assert_equal :disconnected, cleanup.status
    assert_equal 1, cleanup.dropped_envelopes
    assert_equal 0, transport.summary.fetch(:queued_envelopes)
    assert_equal({ disconnected: 1 }, transport.deliver(batch_for("Alice" => "next-stream")).summary)
  end

  def test_retry_pending_delivers_queued_envelope
    adapter = RecordingAdapter.new(failures: 1)
    transport = Upkeep::Delivery::Transport.new(max_queue_size: 2, retry_limit: 3)
    transport.connect(subscriber_id: "Alice", adapter: adapter)

    transport.deliver(batch_for("Alice" => "alice-stream"))
    retry_report = transport.retry_pending(subscriber_id: "Alice")

    assert_equal({ delivered: 1 }, retry_report.summary)
    assert_equal [2], retry_report.outcomes.map(&:attempts)
    assert_equal ["alice-stream"], adapter.bodies
    assert_equal 0, transport.summary.fetch(:queued_envelopes)
  end

  def test_retry_limit_drops_repeated_failures
    adapter = RecordingAdapter.new(failures: 2)
    transport = Upkeep::Delivery::Transport.new(max_queue_size: 2, retry_limit: 2)
    transport.connect(subscriber_id: "Alice", adapter: adapter)

    first_report = transport.deliver(batch_for("Alice" => "alice-stream"))
    retry_report = transport.retry_pending(subscriber_id: "Alice")

    assert_equal({ queued_retry: 1 }, first_report.summary)
    assert_equal({ dropped_retry_exhausted: 1 }, retry_report.summary)
    assert_equal 0, transport.summary.fetch(:queued_envelopes)
    assert_equal "RuntimeError", retry_report.outcomes.first.error_class
  end

  def test_backpressure_reports_full_retry_queue
    adapter = RecordingAdapter.new(failures: 2)
    transport = Upkeep::Delivery::Transport.new(max_queue_size: 1, retry_limit: 3)
    transport.connect(subscriber_id: "Alice", adapter: adapter)

    first_report = transport.deliver(batch_for("Alice" => "first-stream"))
    second_report = transport.deliver(batch_for("Alice" => "second-stream"))

    assert_equal({ queued_retry: 1 }, first_report.summary)
    assert_equal({ backpressured: 1 }, second_report.summary)
    assert_equal 1, transport.summary.fetch(:queued_envelopes)
    assert_equal 1, second_report.outcomes.first.queue_depth
  end

  private

  def batch_for(payloads)
    Batch.new(payloads.map { |subscriber_id, body| Envelope.new(subscriber_id, body) })
  end

  def outcomes_with(report, status)
    report.outcomes.select { |outcome| outcome.status == status }
  end
end
