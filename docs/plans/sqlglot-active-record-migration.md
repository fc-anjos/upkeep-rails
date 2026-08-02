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

Upkeep owns a small Ruby wrapper over the released `sql-glot-rust` C ABI. Its
names, arguments, and result shapes follow the native API:

1. Wrap the existing parse and generation API:
   - `Upkeep::SQLGlot.parse(sql, dialect:)`
   - `Upkeep::SQLGlot.generate(statement, dialect:)`
   - `Upkeep::SQLGlot.transpile(sql, from:, to:)`
2. Project the released semantic API:
   - `MappingSchema`
   - `qualify_columns(statement, schema)`
   - `build_scope(statement)`
   - `lineage(column, statement, schema, config)`
3. Preserve Rust/Python scope and lineage fields. Do not flatten child scope
   collections or introduce an Upkeep-shaped SQLGlot response.

There is deliberately no combined `Upkeep::SQLGlot.analyze` API.

Upkeep-specific lowering remains separate from the sibling API:

```text
Upkeep::SQLGlot.parse + SQL schema
            │
            ▼
Upkeep::SQLGlot::MappingSchema
Upkeep::SQLGlot.qualify_columns
Upkeep::SQLGlot.build_scope
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
so no compatibility decoder, cache migration, top-level `Sqlglot` namespace,
or mixed installation is supported. Installing the release requires a full
bundle/gem reinstall so Bundler selects the matching Upkeep platform gem.

## Native SQLGlot packaging

`upkeep-rails` depends on `ffi` and binds `sql-glot-rust` v0.10.26 directly.
The Ruby boundary lives under `Upkeep::SQLGlot`; there is no external
`sqlglot` Ruby gem dependency and no Upkeep-specific Rust crate or C ABI.

There is one logical gem. Each
release consists of five platform-specific `upkeep-rails` artifacts:

- `x86_64-linux-gnu`;
- `aarch64-linux-gnu`;
- `x86_64-darwin`;
- `arm64-darwin`; and
- `x64-mingw-ucrt`.

The released v0.10.26 tag is built in release CI and its unmodified shared
library is included in each artifact. Rust sources are build inputs and are not
shipped in the gem, so installation never requires Rust. There is deliberately
no generic source artifact.

The v0.10.26 scope builder preserves CTE references as scope sources. Upkeep
does not treat a scope source as a physical table; the AST lowerer resolves the
logical CTE to its physical child and scope validation checks every
schema-backed source.

Active Record SQL types remain available in the Ruby `MappingSchema`. The
native dependency schema represents every column type as `UNKNOWN` because
qualification and lineage inspect table and column identity, not column type.
Database-specific types therefore cannot prevent dependency extraction, and
Upkeep does not maintain a parallel SQL type catalog.

`qualify_columns` expands wildcards by design. Upkeep restores wildcard
projection nodes before dependency lowering so `SELECT table.*` does not add
every model attribute to collection invalidation. Qualification in predicates,
joins, grouping, ordering, and explicit projections is retained.

## Implementation stages

### 1. Establish SQLGlot as an internal runtime boundary

- Bind the released Rust library through `ffi`.
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
- Package the released native library for every supported platform.

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

This milestone is complete in the 0.2.0 release branch: `Upkeep::SQLGlot` is
the only production SQL decoder, the former oracle outputs are frozen as
ordinary expected values, and the Arel collector has been deleted. Remaining
Arel usage in tests constructs Active Record input queries only; no Upkeep
analyzer inspects Arel.

## Execution status

Completed:

- [x] Added `Upkeep::SQLGlot` as the production runtime parser.
- [x] Added generic SQL AST dependency lowering in
  `Upkeep::SQLDependencyAnalysis`.
- [x] Switched `ActiveRecordQuery.analyze` from `Relation#arel` to
  `Upkeep::SQLGlot.parse(relation.to_sql, dialect:)`.
- [x] Kept schema access on Active Record's existing schema cache; Upkeep owns
  no analysis or schema cache.
- [x] Added a separate conservative write-analysis path without introducing a
  collection-query fallback.
- [x] Used `ArelQueryAnalysisOracle` to freeze the parity corpus, then deleted
  the collector and its test-support require.
- [x] Added direct raw-SQL coverage, including correlated subqueries, CTEs,
  set operations, PostgreSQL operators, and MySQL/SQLite functions.
- [x] Bound parse, generate, transpile, `MappingSchema`, qualification, scope,
  and lineage directly to `sql-glot-rust` v0.10.26.
- [x] Decoupled dependency schemas from database type parsing while retaining
  the original SQL types at the Ruby boundary.
- [x] Preserved Rust scope and lineage fields and locked the corrected CTE
  scope-source behavior in a binding test.
- [x] Added five platform-specific `upkeep-rails` artifacts for macOS, Linux,
  and Windows, with no source gem or install-time Cargo build.
- [x] Added an adapter corpus for PostgreSQL, MySQL, and SQLite.
- [x] Added a warm semantic-analysis performance gate with a 2 ms CI budget;
  the local 10,000-iteration mean is approximately 146 µs.
- [x] Verified the full suite and the focused performance gate.
- [x] Removed compatibility and mixed-installation handling; this release
  requires a full reinstall.

Upstream and ecosystem follow-up:

- [x] Open the semantic Ruby bindings in `sql-glot-ruby`.
- [x] Merge the CTE source-overwrite fix in `sql-glot-rust`; it shipped in
      v0.10.24 through
      [`protegrity/sql-glot-rust#26`](https://github.com/protegrity/sql-glot-rust/pull/26).
- [x] Merge and release the Rust semantic C ABI in v0.10.25.
- [x] Delete the Upkeep-specific Rust bridge and external Ruby SQLGlot
      dependency.
- [ ] Continue the Ruby wrapper PRs as optional ecosystem contributions.
