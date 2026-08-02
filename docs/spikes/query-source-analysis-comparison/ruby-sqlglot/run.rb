# frozen_string_literal: true

require "benchmark"
require "json"
require_relative "../../sqlglot-query-analysis/sqlglot_dependency_extractor"

corpus_path = File.expand_path("../corpus.json", __dir__)
physical_corpus_path = File.expand_path("../physical_corpus.json", __dir__)
cases = JSON.parse(File.read(corpus_path))
failures = cases.filter_map do |query_case|
  actual = SqlglotDependencyExtractor
    .tables(query_case.fetch("sql"), dialect: query_case.fetch("dialect").to_sym)
    .map { |table| table.delete_prefix("public.").delete_prefix("main.") }
    .sort
  expected = query_case.fetch("tables").sort
  next if actual == expected

  { name: query_case.fetch("name"), expected: expected, actual: actual }
end

benchmark_case = cases.find { |query_case| query_case.fetch("name") == "PostgreSQL nested IN subquery" }
iterations = 10_000
seconds = Benchmark.realtime do
  iterations.times do
    SqlglotDependencyExtractor.tables(benchmark_case.fetch("sql"), dialect: :postgres)
  end
end

puts JSON.pretty_generate(
  approach: "ruby-sqlglot",
  cases: cases.size,
  failures: failures,
  benchmark_us_per_parse: (seconds * 1_000_000 / iterations).round(1),
  physical_source_failures: JSON.parse(File.read(physical_corpus_path)).filter_map do |query_case|
    actual = SqlglotDependencyExtractor
      .tables(query_case.fetch("sql"), dialect: query_case.fetch("dialect").to_sym)
      .map { |table| table.delete_prefix("public.").delete_prefix("main.") }
      .sort
    expected = query_case.fetch("tables").sort
    next if actual == expected

    { name: query_case.fetch("name"), expected: expected, actual: actual }
  end
)

exit 1 unless failures.empty?
