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
end
