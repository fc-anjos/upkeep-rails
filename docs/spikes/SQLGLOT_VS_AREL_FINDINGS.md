# SQLGlot-first vs Arel, and missing semantic bindings

> Historical note: this investigation predates Upkeep 0.2. Production now uses
> `Upkeep::SQLGlot` and `Upkeep::SQLDependencyAnalysis` as its only query
> decoder; the Arel decoder and migration recommendations below describe the
> path to that release, not the current runtime.

## Outcome

A SQL-first decoder is viable enough to pursue. It can use one policy for both
Active Record-generated SQL and handwritten SQL, while lowering both into a
small generic dependency graph. The spike handles the cases where the current
Arel decoder succeeds and cases it intentionally rejects: raw predicates, raw
joins, correlated `EXISTS`, and CTEs.

This is not yet a drop-in replacement. The current Ruby gem exposes only the
parser-shaped JSON AST. The underlying Rust library has useful semantic APIs,
but v0.10.12 also has correctness gaps that Upkeep must test and either fix
upstream or normalize locally.

## Comparison

| Concern | Current Arel decoder | SQLGlot-first spike |
| --- | --- | --- |
| Hash/Arel predicates | Structural, typed nodes | Parsed from final SQL |
| Raw predicate/order | Rejected as opaque | Analyzed |
| Raw join/source | Rejected as opaque | Analyzed |
| Correlated subquery | Becomes opaque when handwritten | Inner/outer columns and equality edge found |
| CTE | Depends on Arel shape | Physical CTE sources found; CTE name suppressed |
| Simple predicate values | Preserves Ruby values/binds | Recovers SQL literal values |
| Bind type fidelity | Strong | Lost after `to_sql` unless passed separately |
| Parser dependency | Rails/Arel internals | Native SQLGlot dependency |
| Decoder policy | Structured vs opaque branches | One SQL policy with explicit confidence/warnings |

The generic result is deliberately not a catalog of SQL features:

```text
physical source ── referenced column
        │
        ├── equality edge ── other source.column
        └── constant predicate (optional DNF group)

query shape: limit / offset / distinct / group / having
```

SQL constructs belong in the decoder. `DependencyPlan` should only consume the
graph above plus confidence/coverage. That keeps `Linked` source kinds generic.

## Ruby bindings worth adding

The Ruby `sqlglot` gem 0.1.1 currently binds parse, generate, transpile, and
version. The standalone binding proves these existing `sql-glot-rust` APIs are
directly useful:

1. `MappingSchema` + `qualify_columns`
   - resolves unqualified columns using Active Record's schema;
   - expands wildcards;
   - makes alias handling less dependent on a Ruby AST walker.
2. `build_scope`
   - exposes sources per query scope;
   - separates child subqueries and CTE scopes;
   - exposes all columns, including WHERE/JOIN columns;
   - marks external columns and correlated subqueries.
3. `lineage`
   - useful for selected/output values and derived expressions;
   - **not** sufficient for invalidation because filter-only and join-only
     sources are intentionally absent.

One JSON-returning `analyze` FFI entry point is preferable to many fine-grained
calls: parse, qualify, build scopes, and compute requested output lineages in
Rust, then cross the FFI boundary once.

## Challenging observations

- Correlated `EXISTS` works: the inner scope is correlated, includes
  `efforts.milestone_id` and `efforts.status`, and reports
  `milestones.id` as an external column.
- Output lineage for `SELECT milestones.id ... EXISTS (...)` contains
  `milestones` but not `efforts`. The scope tree contains both. Upkeep should
  derive invalidation inputs from scopes/predicates, not output lineage.
- Schema qualification resolves unqualified columns and expands selected
  columns.
- CTE qualification works, and the CTE child scope points at its physical
  table. However, v0.10.12 currently represents the root reference to the CTE
  as `Source::Table("active_cards")`, not `Source::Scope`. This needs an
  upstream fix or a narrowly tested normalizer.
- Parse failures cross the proposed FFI boundary as structured JSON errors,
  rather than null pointers with lost diagnostics.

The earlier Pulse #1802 corpus remains relevant: parsing covers operator
expressions, functions, nested queries, aliases, and raw SQL more uniformly
than class-by-class Arel handling. It does not remove the need for semantic
tests around scope resolution and Rails-emitted dialect details.

## Performance

Warm macOS arm64 measurements over 5,000 analyses:

| Analyzer | Mean per analysis |
| --- | ---: |
| Arel, structured query | 18.3–18.6 µs |
| SQLGlot, same structured query | 47.7 µs |
| SQLGlot, raw join + predicate + order | 89.9–90.3 µs |

The SQL-first path is about 2.6× slower on the comparable structured query, but
still below 0.1 ms in this corpus. Schema metadata was cached; without that
cache, reflection dominated at roughly 0.6 ms.

This analysis should be cached by normalized query shape and schema version. It
should not run once per database change or once per dependent render during
fan-out. The fan-out cost is then graph matching, not SQL parsing.

The standalone release dylib is 3.1 MB on this machine. The complete local Cargo
release directory is larger (88 MB) but is build output, not shipped runtime.

## Recommendation

Proceed with a production-shaped SQL-first prototype behind the existing
`ActiveRecordQuery.analyze` contract:

1. Add the semantic `analyze` binding to the Ruby gem (preferably upstream).
2. Feed it schema data from Active Record's schema cache.
3. Lower its result into one generic dependency graph.
4. Keep Arel temporarily as a parity oracle and as the source of bind values/type
   metadata, not as a second invalidation policy.
5. Run the full query corpus against both decoders and record false-negative,
   conservative, and unsupported results.
6. Remove the Arel decoder only after SQL-first parity and performance targets
   are met.

The key architectural distinction is “two decoders during migration,” not “two
policies forever.”

## Source references

- [`sql-glot-ruby` v0.1.1 native bindings](https://github.com/AccountAim/sql-glot-ruby/blob/v0.1.1/lib/sqlglot/native.rb)
- [`sql-glot-rust` v0.10.12 scope analysis](https://github.com/protegrity/sql-glot-rust/blob/v0.10.12/src/optimizer/scope_analysis.rs)
- [`sql-glot-rust` v0.10.12 column qualification](https://github.com/protegrity/sql-glot-rust/blob/v0.10.12/src/optimizer/qualify_columns.rs)
- [`sql-glot-rust` v0.10.12 lineage](https://github.com/protegrity/sql-glot-rust/blob/v0.10.12/src/optimizer/lineage.rs)
- [Active Record 8.1.3 query methods](https://github.com/rails/rails/blob/v8.1.3/activerecord/lib/active_record/relation/query_methods.rb)
- [Arel 8.1.3 bound SQL literals](https://github.com/rails/rails/blob/v8.1.3/activerecord/lib/arel/nodes/bound_sql_literal.rb)
