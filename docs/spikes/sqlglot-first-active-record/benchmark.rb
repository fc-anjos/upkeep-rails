# frozen_string_literal: true

require "active_record"
require "benchmark"
require_relative "sqlglot_active_record_query"
require_relative "../../../lib/upkeep/active_record_query"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:benchmark_projects) { |t| t.string :name }
  create_table(:benchmark_cards) do |t|
    t.integer :project_id
    t.string :title
    t.string :status
    t.integer :position
  end
end

class BenchmarkCard < ActiveRecord::Base
  self.table_name = "benchmark_cards"
end

relation = BenchmarkCard
  .joins("INNER JOIN benchmark_projects ON benchmark_projects.id = benchmark_cards.project_id")
  .where("benchmark_projects.name = ? AND benchmark_cards.status IN (?, ?)", "Pulse", "open", "blocked")
  .order("benchmark_cards.position DESC")

iterations = Integer(ENV.fetch("N", "1000"))

# The Arel decoder cannot accept this raw query, so use an equivalent structured
# single-table relation for its parse/walk timing and measure SQLGlot on both.
structured = BenchmarkCard.where(status: %w[open blocked]).order(:position)

def elapsed(iterations)
  GC.disable
  Benchmark.realtime { iterations.times { yield } }
ensure
  GC.enable
end

# Warm native loading and Active Record schema caches.
Upkeep::ActiveRecordQuery.analyze(structured)
SqlglotActiveRecordQuery.analyze(structured)
SqlglotActiveRecordQuery.analyze(relation)

arel_seconds = elapsed(iterations) { Upkeep::ActiveRecordQuery.analyze(structured) }
sqlglot_structured_seconds = elapsed(iterations) { SqlglotActiveRecordQuery.analyze(structured) }
sqlglot_raw_seconds = elapsed(iterations) { SqlglotActiveRecordQuery.analyze(relation) }

puts({
  iterations: iterations,
  arel_structured_us: (arel_seconds * 1_000_000 / iterations).round(1),
  sqlglot_structured_us: (sqlglot_structured_seconds * 1_000_000 / iterations).round(1),
  sqlglot_raw_join_us: (sqlglot_raw_seconds * 1_000_000 / iterations).round(1)
})
