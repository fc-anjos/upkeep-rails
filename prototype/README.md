# RefreshSync — proof of the from-scratch upkeep design

A minimal implementation of the redesign proposed in the upkeep retrospective:

- **Read sets from execution, not SQL text.** Loaded record ids come from
  `instantiate_instance_of` (every AR materialization path); membership
  predicates come from a narrow Arel walk of `where_clause` (equality / IN on
  the relation's own table only — the "Electric restriction"). Anything else
  degrades to a table-level dependency with a recorded reason. No SQL parser,
  no native extension.
- **Turbo 8 page refresh is the only delivery action.** No planner, no DAG,
  no template instrumentation, no replay. One debounced
  `Turbo::StreamsChannel.broadcast_refresh_to` per affected cohort per 300ms
  window.
- **Coarse write matching.** `after_commit` per-row changes match by id
  overlap or predicate satisfaction (before or after the write);
  `update_all`/`delete_all`/raw SQL degrade to table-level (any cohort
  reading the table refreshes). Over-refresh is the failure mode, never
  missed updates or wrong content.
- **Zero-subscriber cost is a hash lookup.** Read hooks gate on a
  thread-local recording; write hooks gate on "any cohort watches this
  table".

Carried over from the existing design, deliberately skipped here: the signed
cohort activation handshake / viewer identity, durable store, TTL/pruning,
ActiveJob capture, the browser client.

## Run

    ruby -Iprototype/lib prototype/test/proof_test.rb
    ruby -Iprototype/lib prototype/test/overhead_bench.rb

## Results (2026-08-05, Ruby 3.4.7, Rails 8.1.3, turbo-rails 2.0.23)

- `proof_test.rb`: **10 runs, 50 assertions, 0 failures** (stable across
  repeated runs). Proven end-to-end against a real Rails app + ActionCable
  test adapter + real turbo-rails broadcasts:
  - (a) precision: board-1 page refreshes on board-1 writes, ignores board-2
  - (b) inserts matching / not matching the captured where-predicate
  - (c) 5 rapid writes coalesce into exactly 1 refresh
  - (d) `update_all` and raw SQL `UPDATE` hit the table-level fallback
  - (e) with zero cohorts, the write path does no analysis at all
  - fan-out to multiple viewers; no read analysis outside capture windows
- Capture overhead (order-alternated, same route, toggle on/off):
  **~0.022–0.025 ms per request** (~9% on a 0.26ms trivial page; noise-level
  on any real page). Compare the existing design's 2ms-per-query SQL parse
  budget.
- Library size: **486 LOC** (`lib/`, 8 files) + 289 LOC of tests; zero
  native code, zero new gems.

## What was harder than the design claimed (discoveries)

1. **`instantiate` is dead code in Rails 8.1** — every materialization path
   goes through `instantiate_instance_of` (including `Model.find` via the
   statement cache, which bypasses `Relation#exec_queries` entirely).
   Severity: low, but it is an *internal* API — the read-set hook is coupled
   to Rails internals and needs a per-version compatibility check, exactly
   like turbo-rails does for its own integrations.
2. **Arel node shapes changed in Rails 8.1**: `Equality#right` is a bare
   `ActiveRecord::Relation::QueryAttribute`, not a `BindParam`. The
   defensive posture (unknown node → table-level fallback + reason) made
   this a 5-line fix that the tests caught immediately — evidence that
   fail-open degradation is the right architecture for version drift.
3. **Empty predicates are semantically load-bearing**: an unscoped relation
   (`Card.all`) yields an empty conjunction, which must *match everything*,
   not be discarded. Easy to get wrong silently (missed refreshes).
4. **Raw-SQL write detection is heuristic**: a regex over
   `sql.active_record` payloads filtered by statement name. Fine here only
   because a false positive costs one extra idempotent refresh. A real gem
   should treat this as a supported-surface question (document it, maybe add
   an optional trigger/WAL-based detector).
5. **Benchmarking the overhead honestly required order-alternation** —
   naive before/after measurement showed *negative* overhead from route
   order and warmup bias.

Not hit here but flagged for the real gem: self-refresh suppression
(Turbo's `request-id` handles it, needs the current-request plumbing),
predicate/type coercion across adapters (integer vs string ids), and
debouncer behavior under multi-process deployment (each process debounces
its own writes; cross-process coalescing would need the dedupe window on
the subscriber side or a shared bus).

## Verdict

The from-scratch design holds. Everything the retrospective claimed could
be deleted was deleted, and all five proof properties pass against real
Rails/Turbo machinery. The complications discovered were version-coupling
details (internal AR hook points, Arel node shapes), not architectural
flaws — and the fail-open degradation design absorbed them as intended.
