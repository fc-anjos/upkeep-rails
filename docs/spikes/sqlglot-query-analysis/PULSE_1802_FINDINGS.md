# Pulse #1802 SQLGlot edge-case findings

> Historical note: this investigation predates Upkeep 0.2. Production now uses
> SQLGlot as its only Active Record query decoder with proven column coverage;
> the table-level fallback proposal below is not the current read path.

Date: 2026-07-24

Source: [fetchly/Pulse#1802](https://github.com/fetchly/Pulse/pull/1802)

## Result

SQLGlot can eliminate most of the SQL-to-Arel and SQL-to-Ruby rewrites in this
PR if Upkeep accepts conservative table-level dependencies and replays the
whole render site.

The Ruby SQLGlot 0.1.1 parser plus the scope-aware extractor handled all ten
parseable Pulse-derived cases. One realistic `pg_search` query remains
unparseable because SQLGlot does not recognize pg_trgm's custom `<%`
word-similarity operator.

The same minimal `<%` query also fails with Python SQLGlot 27.20.0. PostgreSQL's
`@@` full-text-search operator, casts, `to_tsquery`, `ts_rank`, and the
`word_similarity(...)` function all parse; `<%` is the isolated failure.

Run the corpus:

```sh
cd docs/spikes/sqlglot-query-analysis
mise exec -- ruby -rbundler/setup pulse_1802_edge_cases_test.rb
```

Observed result:

```text
13 runs, 15 assertions, 0 failures, 0 errors
```

The expected `<%` parse failure is asserted as part of that result.

## PR coverage

| PR query shape | Parse / table extraction | Tables recovered | What this means for Pulse |
| --- | --- | --- | --- |
| `Assignment.current`, `overlapping`, and `current_and_upcoming` nested date predicates | Full | `assignments` | The string predicates did not need Arel rewrites for conservative reactivity. |
| `Effort::Filterable.not_overdue` and `not_design_efforts_types` disjunctions | Full | `efforts` | Ordinary `NULL`, comparison, `AND`, and `OR` predicates are routine. |
| `Project::Staffable#requirements_change_summary` overlapping-range predicate | Full | `project_team_requirements` | This could stay in SQL instead of loading and filtering every requirement in Ruby. |
| `Effort::Filterable.by_blockers` self-correlated `EXISTS` with an alias | Full | `efforts` | The extractor deduplicates the outer and aliased inner physical table. |
| Audit JSONB containment `@>` plus `::jsonb` | Full | `audits` | The helper did not need an `Arel::Nodes::InfixOperation` for table dependency recovery. |
| Audit JSON extraction `-> ... IS NOT NULL` | Full | `audits` | PostgreSQL JSON operators do not block the table-level fallback. |
| `Effort::Filterable.over_budget` correlated `COALESCE(SUM(...), 0)` scalar subquery | Full | `efforts`, `time_logs` | Both the result table and aggregate input table are recovered. |
| `Milestone.status_case_sql` with `CASE`, repeated correlated `EXISTS` / `NOT EXISTS`, and `IN` | Full with custom AST walk | `milestones`, `efforts` | The original SQL can be tracked conservatively. `Sqlglot::Query#tables` alone misses `efforts`. |
| `active_requirements_count` aggregate `SUM(CASE ...)` over a join | Full | `project_team_requirements`, `positions` | It could remain a database aggregate; a change to either table triggers full replay. |
| Two-column `pluck` across a left join | Full | `assignments`, `teams` | Raw projection strings are irrelevant to table discovery. The Arel projection rewrite is not required by this fallback. |
| `pg_search` tsearch-only query and trigram ranking function | Full | `projects` | SQLGlot handles the functions, casts, rank expression, and `@@`. |
| `pg_search` word-similarity predicate using `<%` | **Parse failure** | None | Upkeep must refuse, use a PostgreSQL-specific secondary parser, or add a narrowly tested normalization for custom operators. |

## What “covered” means

Coverage here is deliberately conservative. SQLGlot proves which named tables
can change the result; it does not prove which individual changes alter
membership, ordering, aggregates, or projected values.

For every SQLGlot-derived dependency, Upkeep should therefore:

- subscribe to every recovered table;
- rerun the complete render site on any change to one of those tables; and
- disable append, prepend, remove, and member-replace optimizations.

That is enough to preserve the original SQL for the range filters, JSONB
predicates, correlated subqueries, status `CASE`, aggregate, and `pluck` cases
above. It trades precision for correctness without introducing a second
user-maintained policy.

## What SQLGlot does not address in the PR

- The `<%` custom PostgreSQL operator prevents parsing the complete
  `pg_search` relation. Materializing that relation remains necessary unless
  Upkeep adds another safe fallback.
- SQLGlot cannot discover physical tables hidden behind views or stored
  functions from SQL text alone.
- The milestone row-target and lazy-frame subscription fixes concern render
  capture and subscription lifetime, not query analysis.
- Controller runtime installation and cross-controller invalidation are
  runtime concerns, not parser concerns.
- Parsing an aggregate or `pluck` does not make its result incrementally
  patchable. It only makes full replay safe.

## Recommendation

Use SQLGlot automatically after the precise Arel analyzer fails. For this PR,
that would cover every query rewrite except the full pg_search predicate. Keep
the scope-aware AST extractor: the convenience `Query#tables` API misses the
inner `efforts` and `time_logs` sources in the two hardest cases.

Treat a SQLGlot parse failure as unresolved. If pg_search is important enough
to justify broader coverage, the next focused spike should compare
PostgreSQL's real parser (`pg_query`) against a generic custom-operator
normalization; the latter must not silently alter source structure.
