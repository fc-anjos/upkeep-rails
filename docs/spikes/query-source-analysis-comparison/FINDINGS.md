# Opaque-query source analysis comparison

Date: 2026-07-24

## Decision

Use the Ruby `sqlglot` gem as Upkeep's first automatic fallback when Arel
contains opaque SQL. Keep an Upkeep-owned, scope-aware AST walker and extract
tables only.

Do not add user-selectable query policies. The runtime should follow one
resolution chain:

1. Use Arel for precise column and predicate coverage.
2. Use SQLGlot for conservative named-table coverage.
3. Resolve views through adapter schema metadata where practical.
4. Refuse the boundary when a source remains hidden or unresolvable.

Database-native inspection can improve individual adapters later, but it should
not be the primary cross-adapter mechanism.

## Corpus

The named-source corpus has 12 queries across PostgreSQL, MySQL, and SQLite:

- raw predicates and order expressions;
- raw and schema-qualified joins;
- correlated `EXISTS` and `IN` subqueries;
- derived tables;
- ordinary, shadowing, and recursive CTEs;
- PostgreSQL full-text search; and
- MySQL JSON expressions.

A separate four-case physical-source corpus tests sources hidden behind views
and SQL functions.

The correctness rule is strict: an approach fails if it omits any physical
table that could affect the result. Extra tables are conservative but still
recorded because they increase fanout.

## Results

Benchmarks are local single-process measurements on Apple Silicon. They compare
orders of magnitude, not production latency.

| Approach | Named-source correctness | Local cost | Portability | Finding |
| --- | ---: | ---: | --- | --- |
| Ruby SQLGlot 0.1.1 | 12/12 | ~67 μs/parse | PostgreSQL, MySQL, SQLite; CRuby native gem | Best overall trade-off |
| `sqlparser-rs` 0.62.0 | 12/12 | ~21 μs/parse | Multi-dialect Rust library | Fastest, but Upkeep would own a Ruby binding and native release matrix |
| Python SQLGlot 27.20.0 | 12/12 | ~501 μs/parse | Multi-dialect, separate Python runtime | Correct but operationally inappropriate for a Rails gem |
| `pg_query` 6.2.2 | 4/4 PostgreSQL | ~104 μs/parse | PostgreSQL and CRuby only | Mature and exact for PostgreSQL, but does not solve adapter portability |
| PostgreSQL 17.9 `EXPLAIN (FORMAT JSON)` | 4/4 PostgreSQL | ~82 μs/explain | PostgreSQL connection required | Correct baseline; expands views and stable SQL functions |
| SQLite 3.53 `EXPLAIN QUERY PLAN` text | 5/6 SQLite | ~12 μs/explain | SQLite only | Unsafe: reports aliases instead of physical tables |
| SQLite authorizer during prepare | 6/6 SQLite | ~15 μs/prepare | SQLite only | Correct baseline and exposed by the existing Ruby `sqlite3` gem |

MySQL `EXPLAIN FORMAT=JSON` was not executed because no local MySQL server was
available. Adding it would still leave Upkeep with three adapter-specific
implementations and three different result formats.

## Important failures

### Convenience metadata is not a correctness API

The Ruby SQLGlot wrapper's `Sqlglot::Query#tables` missed tables inside
correlated subqueries, `IN` subqueries, and derived tables. Its underlying AST
contained all sources. The scope-aware recursive extractor in the original
SQLGlot spike recovered all 12 cases.

### Syntax parsers cannot expand database objects

All four parsers return the named view or table function, not the physical
tables behind it:

| Query source | Parser result | Physical dependency |
| --- | --- | --- |
| SQLite `published_posts` view | `published_posts` | `posts` |
| PostgreSQL `active_accounts` view | `active_accounts` | `accounts` |
| PostgreSQL `account_events(42)` | no table, or the function name | `audit.events` |

This is expected: a parser has SQL text but not the connected database schema.

### Query plans are useful but not complete

PostgreSQL JSON `EXPLAIN` expanded:

- the `active_accounts` view to `accounts`; and
- an inlineable `STABLE` SQL function to `audit.events`.

It did not expose the table read by an otherwise identical `VOLATILE` SQL
function. The plan contained a function scan with no underlying relation.
Therefore `EXPLAIN` cannot be treated as a universal proof of physical sources.

SQLite's textual plan reported `physical_posts`, a query alias, instead of the
real `posts` table. Its authorizer callback reported the physical table
correctly, but installing and restoring a connection-global authorizer safely
inside Rails requires concurrency and reentrancy work.

## Dependency and packaging comparison

- Ruby SQLGlot ships precompiled glibc Linux and macOS gems for x86-64 and
  ARM64. Other platforms require Cargo and Git. The current arm64 macOS gem
  includes a roughly 2.4 MB dylib.
- `pg_query` compiled a roughly 3.4 MB native extension locally and embeds the
  real PostgreSQL parser.
- `sqlparser-rs` produced a roughly 7.1 MB standalone release executable in the
  spike. A production choice would require a maintained Ruby extension or FFI
  boundary.
- Python SQLGlot adds an entire second language runtime to a Rails process or
  requires an out-of-process service.

The Ruby SQLGlot wrapper is young. Upkeep should pin its supported version and
keep contract tests for the AST node shapes it consumes.

## Proposed production contract

The fallback analyzer should return one of:

```ruby
Resolved.new(tables: ["posts", "users"], coverage: :tables)
Unresolved.new(reason: "table-valued function account_events")
```

It must never silently convert an empty or partially understood source set into
the model's primary table. Specifically:

- normalize `public.accounts` and `main.posts` to the table names used by
  Active Record change events;
- exclude CTE and derived-table aliases with query-scope awareness;
- validate extracted names against tables and views in the connected schema;
- expand views through adapter metadata or mark them unresolved;
- detect table-valued functions and other source nodes that do not resolve to
  physical tables;
- mark every SQLGlot-derived collection non-appendable; and
- always replay the whole render site for table-coverage dependencies.

This leaves refusal as a correctness outcome, not a configurable policy:
ordinary raw SQL works automatically, while genuinely hidden database behavior
is rejected rather than guessed.

## Reproduction

Each directory is intentionally isolated from production dependencies:

```sh
# Ruby SQLGlot
cd docs/spikes/query-source-analysis-comparison/ruby-sqlglot
mise exec -- ruby -S bundle install
mise exec -- ruby -rbundler/setup run.rb

# pg_query
cd docs/spikes/query-source-analysis-comparison/pg-query
mise exec -- ruby -S bundle install
mise exec -- ruby -rbundler/setup run.rb

# Python SQLGlot
python3 -m venv /tmp/upkeep-python-sqlglot
/tmp/upkeep-python-sqlglot/bin/pip install -r python-sqlglot/requirements.txt
/tmp/upkeep-python-sqlglot/bin/python python-sqlglot/run.py

# sqlparser-rs
cd docs/spikes/query-source-analysis-comparison/sqlparser-rs
mise x rust@stable -- cargo run --release

# SQLite native approaches
python3 docs/spikes/query-source-analysis-comparison/explain/sqlite.py
```

The PostgreSQL runner expects a clean database through `DATABASE_URL`; it
creates schemas, tables, a view, and two functions in that database.
