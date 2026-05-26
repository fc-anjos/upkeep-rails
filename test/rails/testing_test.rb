# frozen_string_literal: true

require "test_helper"

class RailsTestingTest < Minitest::Test
  include Upkeep::Rails::Testing

  def setup
    Upkeep::Rails.configure do |config|
      config.subscription_store = :memory
    end
    Upkeep::Rails.reset_runtime!
  end

  def test_match_report_dry_runs_planner_without_delivery
    subscription = Upkeep::Rails.subscriptions.register(
      subscriber_id: "subscriber-a",
      recorder: recorder_with_page_dependency,
      metadata: { stream_name: "stream-a" }
    )
    Upkeep::Rails.subscriptions.activate(subscription.id)

    report = Upkeep::Rails::Testing.match_report(change)

    assert_equal 1, report.fetch(:candidate_entries)
    assert_equal 1, report.fetch(:matched_entries)
    assert_nil report.fetch(:miss_reason)
    assert_equal [subscription.id], report.fetch(:targets).map { |target| target.fetch(:subscription_id) }
    assert_equal ["page"], report.fetch(:targets).map { |target| target.fetch(:target).fetch(:kind) }
  end

  def test_match_report_exposes_lookup_miss_reason
    report = Upkeep::Rails::Testing.match_report(change)

    assert_equal 0, report.fetch(:candidate_entries)
    assert_equal 0, report.fetch(:matched_entries)
    assert_equal "no_matching_subscriber", report.fetch(:miss_reason)
    assert_empty report.fetch(:targets)
  end

  def test_capture_change_facts_returns_delivered_changes
    _result, facts = Upkeep::Rails::Testing.capture_change_facts do
      Upkeep::Rails.deliver_changes!([change])
    end

    assert_equal [change], facts
  ensure
    Upkeep::Rails::Testing.drain_delivery!
  end

  def test_capture_upkeep_broadcasts_uses_delivery_batch_boundary
    subscription = Upkeep::Rails.subscriptions.register(
      subscriber_id: "subscriber-a",
      recorder: recorder_with_page_dependency,
      metadata: { stream_name: "stream-a" }
    )
    Upkeep::Rails.subscriptions.activate(subscription.id)

    broadcasts = capture_upkeep_broadcasts(subscription) do
      Upkeep::Rails.deliver_changes!([change])
    end

    assert_equal 1, broadcasts.size
    assert_includes broadcasts.first, "turbo-stream"
  end

  def test_delivery_batch_capture_no_ops_when_no_capture_is_active
    batch = Object.new
    def batch.envelopes
      raise "expected envelopes not to be materialized"
    end

    Upkeep::Rails::Testing.record_delivery_batch(batch)
  end

  private

  def recorder_with_page_dependency
    recorder = Upkeep::Runtime::Recorder.new
    recorder.with_frame(
      "page:subscription-store-cards",
      {
        kind: "page",
        recipe: Upkeep::Replay::Recipe.new(
          kind: :page,
          frame_id: "page:subscription-store-cards",
          target_kind: "page",
          target_id: "page:subscription-store-cards"
        ) { "<main>Cards</main>" }
      }
    ) do
      recorder.record_dependency(
        Upkeep::Dependencies::ActiveRecordAttribute.new(
          table: "subscription_store_cards",
          model: "SubscriptionStoreCard",
          id: 1,
          attribute: "title"
        )
      )
    end
    recorder
  end

  def change
    {
      type: "update",
      table: "subscription_store_cards",
      model: "SubscriptionStoreCard",
      id: 1,
      changed_attributes: ["title"],
      old_values: { "title" => "old" },
      new_values: { "title" => "new" }
    }
  end
end
