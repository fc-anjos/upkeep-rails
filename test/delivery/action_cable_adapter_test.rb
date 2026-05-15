# frozen_string_literal: true

require "test_helper"

class ActionCableAdapterTest < Minitest::Test
  Envelope = Data.define(:subscriber_id, :body, :stream_name)
  Batch = Data.define(:envelopes)

  class RecordingCableServer
    attr_reader :broadcasts

    def initialize(failures: 0)
      @failures = failures
      @broadcasts = []
    end

    def broadcast(stream_name, body)
      raise "broadcast failed" if fail?

      broadcasts << [stream_name, body]
    end

    private

    def fail?
      return false if @failures.zero?

      @failures -= 1
      true
    end
  end

  def test_broadcasts_envelope_body_to_canonical_subscriber_stream
    server = RecordingCableServer.new
    adapter = Upkeep::Delivery::ActionCableAdapter.new(server: server)

    adapter.deliver(envelope("person@example.com", "turbo-stream-body"))

    stream_name, body = server.broadcasts.first
    assert_equal "turbo-stream-body", body
    assert_equal Upkeep::Delivery::ActionCableAdapter.stream_name_for("person@example.com"), stream_name
    refute_includes stream_name, "person@example.com"
  end

  def test_broadcasts_to_envelope_stream_name_when_present
    server = RecordingCableServer.new
    adapter = Upkeep::Delivery::ActionCableAdapter.new(server: server)

    adapter.deliver(shared_envelope("upkeep:shared:abc123", "turbo-stream-body"))

    assert_equal [["upkeep:shared:abc123", "turbo-stream-body"]], server.broadcasts
  end

  def test_instruments_delivery_with_digest_and_stream_evidence
    server = RecordingCableServer.new
    adapter = Upkeep::Delivery::ActionCableAdapter.new(server: server)
    events = []
    subscription = ActiveSupport::Notifications.subscribe("deliver.upkeep") { |event| events << event }

    adapter.deliver(envelope("Alice", "alice-stream"))
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription

    event = events.first
    assert_equal "Alice", event.payload.fetch(:subscriber_id)
    assert_equal Upkeep::Delivery::ActionCableAdapter.stream_name_for("Alice"), event.payload.fetch(:stream_name)
    assert_equal Digest::SHA256.hexdigest("alice-stream"), event.payload.fetch(:envelope_digest)
    assert_equal "alice-stream".bytesize, event.payload.fetch(:bytesize)
  end

  def test_transport_delivers_batches_through_action_cable_adapter
    server = RecordingCableServer.new
    transport = Upkeep::Delivery::Transport.new
    transport.connect(
      subscriber_id: "Alice",
      adapter: Upkeep::Delivery::ActionCableAdapter.new(server: server)
    )

    report = transport.deliver(Batch.new([envelope("Alice", "alice-stream")]))

    assert_equal({ delivered: 1 }, report.summary)
    assert_equal [[Upkeep::Delivery::ActionCableAdapter.stream_name_for("Alice"), "alice-stream"]], server.broadcasts
  end

  def test_transport_queues_failed_action_cable_broadcast_for_retry
    server = RecordingCableServer.new(failures: 1)
    transport = Upkeep::Delivery::Transport.new(max_queue_size: 1, retry_limit: 3)
    transport.connect(
      subscriber_id: "Alice",
      adapter: Upkeep::Delivery::ActionCableAdapter.new(server: server)
    )

    first_report = transport.deliver(Batch.new([envelope("Alice", "alice-stream")]))
    retry_report = transport.retry_pending(subscriber_id: "Alice")

    assert_equal({ queued_retry: 1 }, first_report.summary)
    assert_equal({ delivered: 1 }, retry_report.summary)
    assert_equal [[Upkeep::Delivery::ActionCableAdapter.stream_name_for("Alice"), "alice-stream"]], server.broadcasts
  end

  private

  def envelope(subscriber_id, body)
    Envelope.new(subscriber_id, body, nil)
  end

  def shared_envelope(stream_name, body)
    Envelope.new("shared:#{stream_name}", body, stream_name)
  end
end
