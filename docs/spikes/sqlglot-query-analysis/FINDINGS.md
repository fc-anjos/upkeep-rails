# SQLGlot query-analysis spike

> Historical note: this investigation predates Upkeep 0.2. The proposed Arel
> primary path and SQLGlot fallback were superseded by a single generated-SQL
> production path through `Upkeep::SQLGlot` and
> `Upkeep::SQLDependencyAnalysis`.

Date: 2026-07-24

## Question

Can Upkeep use the `sqlglot` Ruby gem to recover table dependencies from
Active Record relations whose Arel nodes contain opaque SQL strings?

## Verdict

Yes, with one important constraint: use SQLGlot's parsed AST and a small
Upkeep-owned recursive table extractor. Do not use
`Sqlglot::Query#tables` as the correctness boundary.

The parser accepted every representative PostgreSQL, MySQL, and SQLite query
in the original corpus. Scope-aware recursive extraction from `Table` AST
nodes recovered every expected source table. The follow-up corpus derived from
Pulse #1802 found one important PostgreSQL extension gap: pg_trgm's custom `<%`
operator does not parse.

## Evidence

The corpus covers:

- raw predicates and order expressions;
- raw joins;
- correlated `EXISTS` subqueries;
- `IN` subqueries;
- derived tables in `FROM` and `JOIN`;
- CTEs;
- CTEs that shadow a physical table;
- recursive CTEs;
- PostgreSQL full-text search;
- PostgreSQL schema-qualified sources;
- MySQL JSON expressions; and
- SQLite quoting and syntax.

Results:

| Path | Result |
| --- | --- |
| SQLGlot parsing | 12/12 query cases parsed |
| `Sqlglot::Query#tables` | 4 failures in the original 10-case corpus |
| Scope-aware AST `Table` extraction | 12/12 table sets correct |
| Invalid SQL | Raised `Sqlglot::ParseError` |
| Local parse/extract benchmark | about 60 μs/query across 10,000 iterations |

The [Pulse #1802 follow-up](PULSE_1802_FINDINGS.md) adds ten parseable,
production-derived cases covering JSONB operators, nested boolean ranges,
self-correlated and aggregate subqueries, repeated `EXISTS`, aggregate
`CASE`, joins, projections, and pg_search expressions. It also preserves the
realistic pg_search `<%` failure as an expected regression test.

The wrapper helper missed physical tables inside correlated subqueries, `IN`
subqueries, and derived tables. The underlying AST contained those tables in
regular nested `Table` nodes, so a generic recursive walk recovered them.

Run the spike:

```sh
cd docs/spikes/sqlglot-query-analysis
mise exec -- ruby -S bundle install
mise exec -- ruby -rbundler/setup sqlglot_query_analysis_test.rb
```

## Proposed Upkeep boundary

Keep the existing Arel analyzer as the precise path. When it encounters an
opaque SQL predicate, order, join, or source:

1. Parse the relation's final SQL using the dialect selected from the Active
   Record adapter.
2. Recursively collect physical `Table` nodes.
3. Remove CTE names from the collected set.
4. Register table-coverage dependencies.
5. Disable append, prepend, remove, and member-replace proofs.
6. Re-run and update the entire render site when any collected table changes.

Only table extraction should ship initially. SQLGlot exposes columns, but
unqualified columns, aliases, projections, and derived outputs require semantic
resolution. They are unnecessary for a correct conservative fallback.

## Risks

- The Ruby wrapper is new (`0.1.1`). Upkeep needs contract tests for the AST
  node shapes it consumes.
- Precompiled gems currently cover glibc Linux and macOS on x86-64 and ARM64.
  Other platforms build the Rust library from source and require Cargo and Git.
- A SQL parser sees named SQL sources, not tables hidden behind database views,
  stored functions, or extensions. Those queries still need a database/schema
  resolver or refusal.
- PostgreSQL permits extension-defined operators. SQLGlot 0.1.1 rejects
  pg_trgm's `<%` word-similarity operator even though it accepts the surrounding
  pg_search tsearch and ranking expressions.
- An extracted schema-qualified name must be normalized to the table names used
  by Upkeep change events.
- Parser success is not proof that every named source corresponds to an
  observed Active Record table. Upkeep must validate extracted names against
  the connected schema before registering them.

## Recommendation

Proceed with SQLGlot as an experimental fallback analyzer behind internal code,
not a user-selectable policy. Keep refusal only as the terminal outcome when
parsing fails or source names cannot be reconciled with Upkeep's observed
schema.

Before merging production integration, expand the corpus with SQL captured from
the benchmark applications and run it on PostgreSQL, MySQL, and SQLite CI.
