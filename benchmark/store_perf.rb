# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "active_record"
require "active_support/notifications"
require "benchmark"
require "tmpdir"
require "upkeep"

N = Integer(ENV.fetch("N", "1000"))
LOOKUPS = Integer(ENV.fetch("LOOKUPS", "50"))
DEPENDENCIES = Integer(ENV.fetch("DEPENDENCIES", "2"))

def recorder_for(id)
  recorder = Upkeep::Runtime::Recorder.new
  attribute_dependencies = [DEPENDENCIES - 1, 1].max

  attribute_dependencies.times do |idx|
    recorder.record_dependency(
      Upkeep::Dependencies::ActiveRecordAttribute.new(
        table: "perf_cards",
        model: "PerfCard",
        id: id,
        attribute: "field_#{idx}"
      )
    )
  end

  recorder.record_dependency(
    Upkeep::Dependencies::ActiveRecordCollection.new(
      primary_table: "perf_cards",
      table_columns: { "perf_cards" => ["id", "status", "field_0"] },
      coverage: :columns,
      sql: "SELECT perf_cards.* FROM perf_cards WHERE status = 'open' ORDER BY id"
    )
  )
  recorder
end

def count_sql
  count = 0
  subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
    count += 1 unless payload[:name].to_s == "SCHEMA" || payload[:cached]
  end

  yield
  count
ensure
  ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
end

def timed_sql
  sql = nil
  elapsed = Benchmark.realtime { sql = count_sql { yield } }
  [elapsed, sql]
end

def emit(rows)
  puts "N=#{N} subscriptions, #{LOOKUPS} lookup iterations, #{DEPENDENCIES} dependencies"
  puts "metric,total_ms,per_op_ms,sql"
  rows.each do |name, elapsed, ops, sql|
    puts format("%s,%.2f,%.4f,%d", name, elapsed * 1000, (elapsed * 1000) / ops, sql)
  end
end

Dir.mktmpdir("upkeep-store-perf") do |dir|
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(dir, "perf.sqlite3"))
  ActiveRecord::Base.logger = nil
  ActiveRecord::Schema.verbose = false
  ActiveRecord::Schema.define do
    create_table :upkeep_subscriptions, id: :string, force: true do |table|
      table.string :subscriber_id, null: false
      table.json :recorder_snapshot, null: false
      table.json :metadata
      table.timestamps
    end

    create_table :upkeep_subscription_index_entries, force: true do |table|
      table.string :subscription_id, null: false
      table.string :lookup_key_digest, null: false
      table.json :lookup_key_snapshot, null: false
      table.json :owner_id_snapshot, null: false
      table.json :dependency_cache_key_snapshot, null: false
      table.json :dependency_snapshot, null: false
      table.timestamps
    end

    add_index :upkeep_subscriptions, :subscriber_id
    add_index :upkeep_subscription_index_entries, :lookup_key_digest
    add_index :upkeep_subscription_index_entries, :subscription_id
  end

  recorders = Array.new(N) { |idx| recorder_for(idx + 1) }
  attribute_change = {
    type: "update",
    table: "perf_cards",
    id: (N / 2) + 1,
    changed_attributes: ["field_0"],
    old_values: { "field_0" => "old" },
    new_values: { "field_0" => "new" }
  }
  collection_change = {
    type: "update",
    table: "perf_cards",
    id: nil,
    changed_attributes: ["status"],
    old_values: {},
    new_values: {}
  }

  memory = Upkeep::Subscriptions::Store.new
  active_record = Upkeep::Subscriptions::ActiveRecordStore.new

  rows = []
  elapsed, sql = timed_sql do
    recorders.each_with_index do |recorder, idx|
      memory.register(subscriber_id: "memory-#{idx}", recorder: recorder, metadata: {})
    end
  end
  rows << ["register memory", elapsed, N, sql]

  elapsed, sql = timed_sql do
    recorders.each_with_index do |recorder, idx|
      active_record.register(subscriber_id: "ar-#{idx}", recorder: recorder, metadata: {})
    end
  end
  rows << ["register active_record", elapsed, N, sql]

  cold_active_record = Upkeep::Subscriptions::ActiveRecordStore.new
  ids = active_record.subscriptions.first(100).map(&:id)

  {
    "lookup attr memory warm" => -> { memory.reverse_index.entries_for([attribute_change]) },
    "lookup attr active_record warm" => -> { active_record.reverse_index.entries_for([attribute_change]) },
    "lookup attr active_record cold" => -> { cold_active_record.reverse_index.entries_for([attribute_change]) },
    "lookup collection memory warm" => -> { memory.reverse_index.entries_for([collection_change]) },
    "lookup collection active_record warm" => -> { active_record.reverse_index.entries_for([collection_change]) },
    "lookup collection active_record cold" => -> { cold_active_record.reverse_index.entries_for([collection_change]) }
  }.each do |name, call|
    elapsed, sql = timed_sql { LOOKUPS.times { call.call } }
    rows << [name, elapsed, LOOKUPS, sql]
  end

  elapsed, sql = timed_sql { ids.each { |id| cold_active_record.fetch(id) } }
  rows << ["fetch 100 active_record cold", elapsed, ids.size, sql]

  emit(rows)
end
