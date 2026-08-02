# frozen_string_literal: true

require "benchmark"
require "json"
require "pg_query"

corpus_path = File.expand_path("../corpus.json", __dir__)
physical_corpus_path = File.expand_path("../physical_corpus.json", __dir__)
cases = JSON.parse(File.read(corpus_path)).select { |query_case| query_case.fetch("dialect") == "postgres" }
failures = cases.filter_map do |query_case|
  actual = PgQuery.parse(query_case.fetch("sql")).tables.map { |table| table.delete_prefix("public.") }.sort
  expected = query_case.fetch("tables").sort
  next if actual == expected

  { name: query_case.fetch("name"), expected: expected, actual: actual }
end

benchmark_case = cases.find { |query_case| query_case.fetch("name") == "PostgreSQL nested IN subquery" }
iterations = 10_000
seconds = Benchmark.realtime do
  iterations.times { PgQuery.parse(benchmark_case.fetch("sql")).tables }
end

puts JSON.pretty_generate(
  approach: "pg-query",
  cases: cases.size,
  failures: failures,
  benchmark_us_per_parse: (seconds * 1_000_000 / iterations).round(1),
  physical_source_failures: JSON.parse(File.read(physical_corpus_path))
    .select { |query_case| query_case.fetch("dialect") == "postgres" }
    .filter_map do |query_case|
      actual = PgQuery.parse(query_case.fetch("sql")).tables
        .map { |table| table.delete_prefix("public.") }
        .sort
      expected = query_case.fetch("tables").sort
      next if actual == expected

      { name: query_case.fetch("name"), expected: expected, actual: actual }
    end
)

exit 1 unless failures.empty?
