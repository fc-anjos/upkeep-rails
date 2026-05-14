# frozen_string_literal: true

require "test_helper"

class ChangeEventCard < ActiveRecord::Base
  self.table_name = "change_event_cards"
end

class ChangeEventsTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :change_event_cards, force: true do |table|
        table.string :title, null: false
        table.string :status, null: false
        table.integer :position, null: false
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def test_create_event_records_old_and_new_values
    card = ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    event = Upkeep::Runtime::ChangeLog.events.fetch(0)

    assert_equal "create", event.fetch(:type)
    assert_equal "change_event_cards", event.fetch(:table)
    assert_equal "ChangeEventCard", event.fetch(:model)
    assert_equal card.id, event.fetch(:id)
    assert_includes event.fetch(:changed_attributes), "title"
    assert_nil event.fetch(:old_values).fetch("title")
    assert_equal "Plan", event.fetch(:new_values).fetch("title")
    assert_equal({ old: nil, new: "Plan" }, event.fetch(:attribute_changes).fetch("title"))
  end

  def test_update_event_records_changed_attribute_values
    card = ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    Upkeep::Runtime::ChangeLog.reset
    card.update!(status: "done")

    event = Upkeep::Runtime::ChangeLog.events.fetch(0)

    assert_equal "update", event.fetch(:type)
    assert_equal card.id, event.fetch(:id)
    assert_equal ["status"], event.fetch(:changed_attributes)
    assert_equal "open", event.fetch(:old_values).fetch("status")
    assert_equal "done", event.fetch(:new_values).fetch("status")
    assert_equal({ old: "open", new: "done" }, event.fetch(:attribute_changes).fetch("status"))
  end

  def test_update_column_records_record_scoped_update_event
    card = ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    Upkeep::Runtime::ChangeLog.reset
    card.update_column(:position, 2)

    event = Upkeep::Runtime::ChangeLog.events.fetch(0)

    assert_equal "update", event.fetch(:type)
    assert_equal "change_event_cards", event.fetch(:table)
    assert_equal "ChangeEventCard", event.fetch(:model)
    assert_equal card.id, event.fetch(:id)
    assert_equal ["position"], event.fetch(:changed_attributes)
    assert_empty event.fetch(:old_values)
    assert_equal 2, event.fetch(:new_values).fetch("position")
    assert_equal({ old: nil, new: 2 }, event.fetch(:attribute_changes).fetch("position"))
  end

  def test_destroy_event_records_old_values_for_deleted_record
    card = ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    Upkeep::Runtime::ChangeLog.reset
    card.destroy!

    event = Upkeep::Runtime::ChangeLog.events.fetch(0)

    assert_equal "destroy", event.fetch(:type)
    assert_equal card.id, event.fetch(:id)
    assert_includes event.fetch(:changed_attributes), "id"
    assert_includes event.fetch(:changed_attributes), "title"
    assert_equal "Plan", event.fetch(:old_values).fetch("title")
    assert_empty event.fetch(:new_values)
    assert_equal({ old: "Plan", new: nil }, event.fetch(:attribute_changes).fetch("title"))
  end

  def test_bulk_update_event_preserves_conservative_predicate_context
    ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    Upkeep::Runtime::ChangeLog.reset
    ChangeEventCard.where(status: "open").update_all(status: "done")

    event = Upkeep::Runtime::ChangeLog.events.fetch(0)

    assert_equal "bulk_update", event.fetch(:type)
    assert_equal "ChangeEventCard", event.fetch(:model)
    assert_equal ["status"], event.fetch(:changed_attributes)
    assert_empty event.fetch(:old_values)
    assert_equal "done", event.fetch(:new_values).fetch("status")
    assert_equal({ old: nil, new: "done" }, event.fetch(:attribute_changes).fetch("status"))
    assert_equal :columns, event.fetch(:predicate_coverage).to_sym
    assert_includes event.fetch(:predicate_table_columns).fetch("change_event_cards"), "status"
  end

  def test_bulk_delete_event_preserves_conservative_predicate_context
    ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    Upkeep::Runtime::ChangeLog.reset
    ChangeEventCard.where(status: "open").delete_all

    event = Upkeep::Runtime::ChangeLog.events.fetch(0)

    assert_equal "bulk_delete", event.fetch(:type)
    assert_equal "ChangeEventCard", event.fetch(:model)
    assert_equal ["id"], event.fetch(:changed_attributes)
    assert_empty event.fetch(:old_values)
    assert_empty event.fetch(:new_values)
    assert_equal({ old: nil, new: nil }, event.fetch(:attribute_changes).fetch("id"))
    assert_equal :columns, event.fetch(:predicate_coverage).to_sym
    assert_includes event.fetch(:predicate_table_columns).fetch("change_event_cards"), "status"
  end

  def test_relation_materialization_records_provenance_without_collection_dependency
    ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    result, recorder = Upkeep::Runtime::Observation.capture_request do
      ChangeEventCard.where(status: "missing").to_a
    end

    provenance = recorder.relation_provenance_for(result)

    assert provenance
    assert_equal "ChangeEventCard", provenance.model_name
    assert_equal "change_event_cards", provenance.primary_table
    assert_includes provenance.table_columns.fetch("change_event_cards"), "status"
    refute_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_collection"
  end

  def test_opaque_relation_materialization_raises_before_querying
    ChangeEventCard.create!(title: "Plan", status: "open", position: 1)
    select_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      select_sql << sql if sql.start_with?("SELECT") && sql.include?('"change_event_cards"')
    end

    error = assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) do
      Upkeep::Runtime::Observation.capture_request do
        ChangeEventCard.where("status = ?", "open").to_a
      end
    end

    assert_includes error.message, "cannot make this Active Record relation reactive"
    assert_includes error.message, "raw SQL predicate"
    assert_empty select_sql
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_warn_policy_refuses_opaque_relation_materialization_without_dependency
    previous_behavior = Upkeep::Rails.configuration.refused_boundary_behavior
    Upkeep::Rails.configuration.refused_boundary_behavior = :warn
    ChangeEventCard.create!(title: "Plan", status: "open", position: 1)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("refused_boundary.upkeep") do |_name, _started, _finished, _id, payload|
      events << payload
    end

    result, recorder = Upkeep::Runtime::Observation.capture_request do
      ChangeEventCard.where("status = ?", "open").to_a
    end

    assert_equal ["Plan"], result.map(&:title)
    refute recorder.reactive?
    assert_equal 1, recorder.refused_boundaries.size
    assert_equal "opaque_active_record_relation", recorder.refused_boundaries.first.reason
    assert_equal "active_record_relation", recorder.refused_boundaries.first.source
    assert_includes recorder.refused_boundaries.first.suggestions.join(" "), "structural Active Record"
    assert_includes events.map { |event| event.fetch(:reason) }, "opaque_active_record_relation"
    refute_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_collection"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Upkeep::Rails.configuration.refused_boundary_behavior = previous_behavior if previous_behavior
  end

  def test_relation_pluck_records_query_dependency_without_collection_dependency
    ChangeEventCard.create!(title: "Plan", status: "open", position: 1)

    result, recorder = Upkeep::Runtime::Observation.capture_request do
      ChangeEventCard.where(status: "open").pluck(:title)
    end

    dependency_sources = recorder.graph.summary.fetch(:dependency_sources)
    dependency = recorder.graph.dependency_nodes.map(&:payload).find do |candidate|
      candidate.source == :active_record_query
    end

    assert_equal ["Plan"], result
    assert dependency
    assert_includes dependency.metadata.fetch(:table_columns).fetch("change_event_cards"), "status"
    assert_includes dependency.metadata.fetch(:table_columns).fetch("change_event_cards"), "title"
    assert_includes dependency_sources, "active_record_query"
    refute_includes dependency_sources, "active_record_collection"
  end

  def test_opaque_pluck_column_raises_before_querying
    ChangeEventCard.create!(title: "Plan", status: "open", position: 1)
    select_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      select_sql << sql if sql.start_with?("SELECT") && sql.include?('"change_event_cards"')
    end

    error = assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) do
      Upkeep::Runtime::Observation.capture_request do
        ChangeEventCard.where(status: "open").pluck("LOWER(title)")
      end
    end

    assert_includes error.message, "opaque pluck column"
    assert_empty select_sql
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
