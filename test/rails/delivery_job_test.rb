# frozen_string_literal: true

require "test_helper"
require "active_job"

class DeliveryJobTest < Minitest::Test
  def setup
    @previous_delivery_adapter = Upkeep::Rails.configuration.delivery_adapter
    @previous_delivery_queue = Upkeep::Rails.configuration.delivery_queue
    @previous_active_job_adapter = ActiveJob::Base.queue_adapter
    @previous_active_job_logger = ActiveJob::Base.logger
    ActiveJob::Base.logger = nil
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
    Upkeep::Rails.configuration.delivery_adapter = :active_job
    Upkeep::Rails.configuration.delivery_queue = :upkeep_realtime
  end

  def teardown
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear if ActiveJob::Base.queue_adapter.respond_to?(:enqueued_jobs)
    ActiveJob::Base.queue_adapter.performed_jobs.clear if ActiveJob::Base.queue_adapter.respond_to?(:performed_jobs)
    ActiveJob::Base.queue_adapter = @previous_active_job_adapter
    ActiveJob::Base.logger = @previous_active_job_logger
    Upkeep::Rails.configuration.delivery_adapter = @previous_delivery_adapter
    Upkeep::Rails.configuration.delivery_queue = @previous_delivery_queue
  end

  def test_active_job_adapter_enqueues_delivery_job_on_configured_queue
    report = Upkeep::Rails.deliver_changes!([delivery_change])
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last

    assert_instance_of Upkeep::Delivery::Transport::DispatchReport, report
    assert_equal Upkeep::Rails::DeliveryJob, job.fetch(:job)
    assert_equal "upkeep_realtime", job.fetch(:queue)
    serialized_change = job.fetch(:args).first.first
    assert_equal "cards", serialized_change.fetch("table")
    assert_includes serialized_change.fetch("_aj_symbol_keys"), "table"
  end

  def test_delivery_job_normalizes_string_keys_before_delivering_now
    captured = Upkeep::Rails::DeliveryJob.new.send(:normalize_changes, [
      "type" => "update",
      "table" => "cards",
      "model" => "Card",
      "id" => 1,
      "changed_attributes" => ["title"],
      "old_values" => { "title" => "Plan" },
      "new_values" => { "title" => "Plan v2" }
    ])

    assert_includes captured.first.keys, :type
    assert_equal "update", captured.first.fetch(:type)
    assert_equal "cards", captured.first.fetch(:table)
    assert_equal ["title"], captured.first.fetch(:changed_attributes)
  end

  def test_active_job_enqueue_failure_is_instrumented_and_does_not_raise
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(Upkeep::Rails::DELIVERY_ENQUEUE_ERROR) do |event|
      events << event
    end

    ActiveJob::Base.queue_adapter = FailingQueueAdapter.new

    report = Upkeep::Rails.deliver_changes!([delivery_change])

    assert_instance_of Upkeep::Delivery::Transport::DispatchReport, report

    assert_equal 1, events.size
    assert_equal :active_job, events.first.payload.fetch(:adapter)
    assert_equal :upkeep_realtime, events.first.payload.fetch(:queue)
    assert_equal "RuntimeError", events.first.payload.fetch(:error_class)
    assert_equal "queue down", events.first.payload.fetch(:error_message)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_unknown_delivery_adapter_is_rejected
    error = assert_raises(Upkeep::Rails::ConfigurationError) do
      Upkeep::Rails.configuration.delivery_adapter = :sidekiq
    end

    assert_includes error.message, "Unknown Upkeep delivery_adapter"
  end

  private

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

class FailingQueueAdapter
  def enqueue(_job)
    raise "queue down"
  end

  def enqueue_at(job, _timestamp)
    enqueue(job)
  end
end
