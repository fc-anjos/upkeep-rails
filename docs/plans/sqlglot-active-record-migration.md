# SQLGlot Active Record query-analysis migration

## Goal

Make SQLGlot the only production decoder for Active Record relation
dependencies in the next Upkeep release. Keep the existing Arel decoder only as
a test/development parity oracle until the SQLGlot corpus proves it can be
deleted.

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

Upkeep-specific lowering remains separate:

```text
Sqlglot.parse + SQL schema
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
- Before release, add native semantic sibling bindings with the matching API
  described above and submit the same APIs/fixes upstream. The sibling keeps
  Upkeep unblocked; upstream adoption later removes it without changing callers.

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

This implementation stops with SQLGlot as the production path and Arel as a
test-only oracle. Removing the oracle and completing native platform packaging
are follow-up milestones gated by the exit criteria above.

## Execution status

Completed for this milestone:

- [x] Added `sqlglot` as the production runtime parser.
- [x] Added generic SQL AST dependency lowering in
  `Upkeep::SQLDependencyAnalysis`.
- [x] Switched `ActiveRecordQuery.analyze` from `Relation#arel` to
  `Sqlglot.parse(relation.to_sql, dialect:)`.
- [x] Kept schema access on Active Record's existing schema cache; Upkeep owns
  no analysis or schema cache.
- [x] Added a separate conservative write-analysis path without introducing a
  collection-query fallback.
- [x] Moved the Arel collector into test support as
  `ArelQueryAnalysisOracle`.
- [x] Added oracle parity and direct raw-SQL coverage, including correlated
  subqueries, CTEs, and set operations.
- [x] Verified the full suite and the focused performance gate.
- [x] Removed compatibility and mixed-installation handling; this release
  requires a full reinstall.

Release follow-up:

- [ ] Package native semantic sibling bindings for APIs missing from the Ruby
  implementation, matching the established Rust/Python names and result shapes.
- [ ] Expand the adapter corpus and satisfy the oracle exit criteria before
  deleting the test-only Arel oracle.
