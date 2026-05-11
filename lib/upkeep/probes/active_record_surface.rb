# frozen_string_literal: true

require "active_record"
require "json"
require "pathname"
require "time"

module Upkeep
  module Probes
  end
end

class Upkeep::Probes::ActiveRecordSurface
  module FrameRecorder
    THREAD_KEY = :upkeep_ar_events

    module_function

    def capture
      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        next if payload[:name] == "SCHEMA"

        record({
          type: "sql",
          name: payload[:name],
          sql: payload[:sql]
        })
      end

      yield
      Thread.current[THREAD_KEY]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      Thread.current[THREAD_KEY] = previous
    end

    def record(event)
      events = Thread.current[THREAD_KEY]
      events << event if events
    end
  end

  module ChangeLog
    @events = []

    module_function

    def reset
      @events = []
    end

    def record(event)
      @events << event
    end

    def events
      @events
    end
  end

  module RelationObserver
    def exec_main_query(async: false)
      FrameRecorder.record({
        type: "relation_exec",
        model: klass.name,
        table: klass.table_name,
        sql: safe_sql
      })

      super
    end

    def exec_queries(&block)
      FrameRecorder.record({
        type: "relation_exec",
        model: klass.name,
        table: klass.table_name,
        sql: safe_sql
      })

      super
    end

    def pluck(*column_names)
      FrameRecorder.record({
        type: "relation_pluck",
        model: klass.name,
        table: klass.table_name,
        columns: column_names.map(&:to_s),
        sql: safe_sql
      })

      super
    end

    def calculate(operation, column_name)
      FrameRecorder.record({
        type: "relation_calculate",
        model: klass.name,
        table: klass.table_name,
        operation: operation.to_s,
        column: column_name.to_s,
        sql: safe_sql
      })

      super
    end

    def update_all(updates)
      ChangeLog.record({
        type: "bulk_update",
        model: klass.name,
        table: klass.table_name,
        updates: updates.inspect,
        predicate_sql: safe_sql
      })

      super
    end

    def delete_all
      ChangeLog.record({
        type: "bulk_delete",
        model: klass.name,
        table: klass.table_name,
        predicate_sql: safe_sql
      })

      super
    end

    private

    def safe_sql
      to_sql
    rescue StandardError => error
      "#{error.class}: #{error.message}"
    end
  end

  module AttributeObserver
    def _read_attribute(attr_name, &block)
      value = super

      FrameRecorder.record({
        type: "attribute_read",
        model: self.class.name,
        table: self.class.table_name,
        id: primary_key_value(attr_name, value),
        attribute: attr_name.to_s
      })

      value
    end

    private

    def primary_key_value(attr_name, value)
      primary_key = self.class.primary_key
      return nil unless primary_key
      return value if attr_name.to_s == primary_key.to_s

      @attributes.fetch_value(primary_key)
    rescue StandardError
      nil
    end
  end

  module AssociationObserver
    def load_target
      FrameRecorder.record({
        type: "association_load",
        owner_model: owner.class.name,
        owner_table: owner.class.table_name,
        owner_id: owner.id,
        association: reflection.name.to_s,
        target_model: reflection.klass.name,
        target_table: reflection.klass.table_name
      })

      super
    end
  end

  class Board < ActiveRecord::Base
    self.table_name = "boards"

    has_many :cards, class_name: "Upkeep::Probes::ActiveRecordSurface::Card", foreign_key: :board_id
  end

  class Card < ActiveRecord::Base
    self.table_name = "cards"

    belongs_to :board, class_name: "Upkeep::Probes::ActiveRecordSurface::Board"
  end

  def initialize(project_root:)
    @project_root = Pathname(project_root)
  end

  def run
    install_observers
    setup_database
    seed_records

    read_events = capture_render_like_read
    callback_change_events = capture_callback_write
    bulk_change_events = capture_bulk_write

    {
      generated_at: Time.now.utc.iso8601,
      summary: {
        read_events: read_events.size,
        callback_change_events: callback_change_events.size,
        bulk_change_events: bulk_change_events.size,
        event_types: read_events.map { |event| event.fetch(:type) }.uniq.sort
      },
      read_events: read_events,
      callback_change_events: callback_change_events,
      bulk_change_events: bulk_change_events
    }
  end

  private

  attr_reader :project_root

  def install_observers
    return if self.class.instance_variable_get(:@installed)

    ActiveRecord::Relation.prepend(RelationObserver)
    ActiveRecord::AttributeMethods::Read.prepend(AttributeObserver)
    ActiveRecord::Associations::Association.prepend(AssociationObserver)
    ActiveRecord::Associations::CollectionAssociation.prepend(AssociationObserver)
    ActiveRecord::Associations::SingularAssociation.prepend(AssociationObserver)

    ActiveRecord::Base.after_commit do |record|
      ChangeLog.record({
        type: "after_commit",
        model: record.class.name,
        table: record.class.table_name,
        id: record.id,
        changed_attributes: record.previous_changes.keys.map(&:to_s).sort
      })
    end

    self.class.instance_variable_set(:@installed, true)
  end

  def setup_database
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :boards, force: true do |table|
        table.string :name, null: false
      end

      create_table :cards, force: true do |table|
        table.references :board, null: false
        table.string :title, null: false
        table.string :status, null: false
        table.integer :position, null: false
      end
    end
  end

  def seed_records
    ChangeLog.reset

    board = Board.create!(name: "Launch")
    Board.create!(name: "Archive")

    Card.create!(board: board, title: "Plan", status: "open", position: 1)
    Card.create!(board: board, title: "Build", status: "open", position: 2)
    Card.create!(board: board, title: "Review", status: "blocked", position: 3)

    ChangeLog.reset
  end

  def capture_render_like_read
    FrameRecorder.capture do
      board = Board.find_by!(name: "Launch")
      board.name

      board.cards.each do |card|
        card.title
        card.status
        card.position
      end

      Card.where(status: "open").order(:position).pluck(:title)
      Card.where(status: "open").count
    end
  end

  def capture_callback_write
    ChangeLog.reset

    Card.find_by!(title: "Plan").update!(status: "done")

    ChangeLog.events
  end

  def capture_bulk_write
    ChangeLog.reset

    Card.where(status: "blocked").update_all(status: "open")

    ChangeLog.events
  end
end
