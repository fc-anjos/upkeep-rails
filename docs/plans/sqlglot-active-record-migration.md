# SQLGlot Active Record query-analysis migration

## Goal

Make SQLGlot the only production decoder for Active Record relation
dependencies in the next Upkeep release. Use the former Arel oracle to freeze a
parity corpus, then delete the oracle once the SQLGlot, raw-SQL, and adapter
corpora prove the same dependencies.

“Drop Arel” means Upkeep production code does not call `Relation#arel`, inspect
Arel nodes, or select a structured/unstructured policy. Active Record may still
use Arel internally to generate `Relation#to_sql`.

## API boundary

Upkeep must not invent SQLGlot APIs. Where semantic APIs need to be added as a
sibling extension, their names, arguments, and result shapes must match an
existing implementation:

1. Preserve the existing Ruby API:
   - `Sqlglot.parse(sql, dialect:)`
   - `Sqlglot.generate(statement, dialect:)`
   - `Sqlglot.transpile(sql, from:, to:)`
2. Mirror `sql-glot-rust` for APIs absent from Ruby:
   - `MappingSchema`
   - `qualify_columns(statement, schema)`
   - `build_scope(statement)`
   - `lineage(column, statement, schema, config)`
3. Preserve Rust/Python scope and lineage fields. Do not flatten child scope
   collections or introduce an Upkeep-shaped SQLGlot response.

There is deliberately no public `Upkeep::Sqlglot.analyze` API.

Upkeep-specific lowering remains separate from the sibling API:

```text
Sqlglot.parse + SQL schema
            │
            ▼
Sqlglot::MappingSchema
Sqlglot.qualify_columns
Sqlglot.build_scope
            │
            ▼
Upkeep::SQLDependencyAnalysis
            │
            ▼
Upkeep::ActiveRecordQuery::Result
```

`SQLDependencyAnalysis` owns physical dependency sources, referenced columns,
simple predicate DNF, equality edges, query shape, and conservative warnings.
`ActiveRecordQuery` owns model table, primary key, adapter dialect, schema
extraction, and the internal result contract.

This release is intentionally breaking. There are no existing users to migrate,
so no compatibility decoder, cache migration, or mixed installation is
supported. Installing the release requires a full bundle/gem reinstall so the
SQLGlot platform dependency is installed cleanly.

## Embedded semantic extension

`upkeep-rails` depends on `sqlglot` 0.1.1 and temporarily embeds the missing
semantic bindings, pinned to `sql-glot-rust` v0.10.12. The extension's public
API reopens the `Sqlglot` namespace with the established Rust primitives; its
private C ABI contains one function per primitive and no combined Upkeep
analyzer.

There is one logical gem and no separately published semantics gem. Each
release consists of four platform-specific `upkeep-rails` artifacts:

- `x86_64-linux-gnu`;
- `aarch64-linux-gnu`;
- `x86_64-darwin`; and
- `arm64-darwin`.

The native library is built in release CI and included in each artifact.
Cargo sources remain private repository/build inputs and are not shipped in
the gem, so installation never requires Rust. There is deliberately no generic
source artifact. This release requires a full reinstall on a supported
platform.

When the semantic APIs are accepted upstream, the embedded extension can be
deleted and `upkeep-rails` can use `sqlglot` directly without changing its
callers.

The v0.10.12 scope builder exposes a CTE child correctly but overwrites the
outer CTE source with a table-shaped source. The extension preserves that
upstream result shape. Upkeep does not treat a scope table as physical unless
it exists in `MappingSchema`; the AST lowerer resolves the logical CTE to its
physical child and scope validation checks every schema-backed source.

`qualify_columns` expands wildcards by design. Upkeep restores wildcard
projection nodes before dependency lowering so `SELECT table.*` does not add
every model attribute to collection invalidation. Qualification in predicates,
joins, grouping, ordering, and explicit projections is retained.

## Implementation stages

### 1. Establish SQLGlot as a runtime dependency

- Add the Ruby `sqlglot` gem at the tested version.
- Add adapter-to-dialect mapping.
- Convert Active Record schema metadata into SQLGlot-compatible table/column
  metadata, retaining SQL types where available.
- Fail closed with an actionable SQL analysis error; never silently subscribe
  only to the primary table after an unknown joined source.

### 2. Productize dependency lowering

- Move the SQL-first spike into `Upkeep::SQLDependencyAnalysis`.
- Accept SQL AST, dialect, and schema only—no relation or model objects.
- Keep SQL constructs inside this decoder and lower them into a generic graph:
  physical tables, columns, equality edges, predicate groups, and query shape.
- Treat CTEs and derived sources as logical sources backed by physical tables.
- Record ambiguity as conservative coverage or an unsupported analysis, never
  as a missing dependency.

### 3. Switch the Active Record runtime path

- Make `ActiveRecordQuery.analyze` parse `relation.to_sql` with SQLGlot.
- Preserve `ActiveRecordQuery::Result` so invalidation/replay consumers do not
  need a simultaneous rewrite.
- Give write observation a separate `analyze_for_write` entry point. It may
  conservatively describe the model table when semantic predicate analysis
  fails; this is not a collection-query decoder or runtime fallback.
- Update opaque-query guidance so it no longer asks users to rewrite SQL as
  Arel.

### 4. Move Arel to an oracle

- Move the current collector to test support and rename it
  `ArelQueryAnalysisOracle`.
- Production `lib/` must contain no Arel node dispatch and no
  `Relation#arel` call.
- Compare the oracle with SQLGlot for relations the oracle can prove.
- SQLGlot may report additional safe dependencies. It must not omit any table,
  column, predicate, or query-shape restriction proven by the oracle.
- Raw SQL cases that the oracle rejects are asserted directly against SQLGlot.

### 5. Verification and release hardening

- Cover existing query-analysis tests and Pulse #1802 edge cases.
- Add raw predicate, raw join, alias/self-join, correlated subquery, CTE,
  function/operator, `IN`, null, negation, OR-DNF, group/having/distinct,
  limit/offset, and parse-error cases.
- Run the full Upkeep suite.
- Benchmark parsing separately from invalidation fan-out. This milestone does
  not add an Upkeep-owned analysis or schema cache.
- Add embedded native semantic bindings with the matching API described above.
  The extension keeps Upkeep unblocked; upstream adoption later removes it
  without changing callers.

## Oracle exit criteria

Arel can be deleted after:

- the supported adapter corpus has no known dependency false negatives;
- SQLGlot covers every relation the oracle proves;
- raw SQL coverage has dedicated assertions;
- unsupported SQL fails with query, dialect, and parser diagnostics;
- production code has no oracle switch or fallback;
- analysis stays outside invalidation fan-out and meets the agreed performance
  budget.

## Current milestone

This milestone is complete: SQLGlot plus the embedded semantic extension is the only
production path, the former oracle outputs are frozen as ordinary expected
values, and the Arel collector has been deleted. Remaining Arel usage in tests
constructs Active Record input queries only; no Upkeep analyzer inspects Arel.

## Execution status

Completed:

- [x] Added `sqlglot` as the production runtime parser.
- [x] Added generic SQL AST dependency lowering in
  `Upkeep::SQLDependencyAnalysis`.
- [x] Switched `ActiveRecordQuery.analyze` from `Relation#arel` to
  `Sqlglot.parse(relation.to_sql, dialect:)`.
- [x] Kept schema access on Active Record's existing schema cache; Upkeep owns
  no analysis or schema cache.
- [x] Added a separate conservative write-analysis path without introducing a
  collection-query fallback.
- [x] Used `ArelQueryAnalysisOracle` to freeze the parity corpus, then deleted
  the collector and its test-support require.
- [x] Added direct raw-SQL coverage, including correlated subqueries, CTEs,
  set operations, PostgreSQL operators, and MySQL/SQLite functions.
- [x] Embedded `MappingSchema`, `qualify_columns`, `build_scope`, and `lineage`
  in `upkeep-rails`, matching the established SQLGlot APIs.
- [x] Preserved Rust scope and lineage fields and locked the v0.10.12 CTE
  behavior in a binding test.
- [x] Added four platform-specific `upkeep-rails` artifacts for macOS/Linux on
  arm64/x86-64, with no source gem or install-time Cargo build.
- [x] Added an adapter corpus for PostgreSQL, MySQL, and SQLite.
- [x] Added a warm semantic-analysis performance gate with a 2 ms CI budget;
  the local 10,000-iteration mean is approximately 146 µs.
- [x] Verified the full suite and the focused performance gate.
- [x] Removed compatibility and mixed-installation handling; this release
  requires a full reinstall.

Upstream follow-up:

- [ ] Submit the semantic Ruby bindings to `sql-glot-ruby`.
- [x] Merge the CTE source-overwrite fix in `sql-glot-rust`; it shipped in
      v0.10.24 through
      [`protegrity/sql-glot-rust#26`](https://github.com/protegrity/sql-glot-rust/pull/26).
- [ ] Merge and release the Rust semantic C ABI. A fork-only draft is open for
      review at
      [`fc-anjos/sql-glot-rust#1`](https://github.com/fc-anjos/sql-glot-rust/pull/1).
- [ ] Delete the embedded extension in favor of upstream releases once both are
  available, without changing Upkeep callers.
