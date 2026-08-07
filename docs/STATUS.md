# Upkeep 0.3 — status ledger

Last updated: 2026-08-07, branch `refresh-sync` @ `9bdb22f`.
Suite: 36 suites / 266 runs / 1291 assertions, green on Rails 8.1 and 7.1.
CI (GitHub Actions, `fc-anjos/upkeep-rails`): green through `4ce199f`;
`9bdb22f` in progress at time of writing.

## What upkeep 0.3 is

A complete architectural replacement of 0.2.x (SQL parsing as correctness
authority, template rewriting, DAG planner, controller replay — all deleted,
net −50k lines). The 0.3 model:

- **Read sets from execution.** Loaded ids, column reads, hash predicates,
  parsed fragment predicates — recorded at Active Record choke points during
  real renders. Never derived from static analysis of app code.
- **Two-tier delivery.** Tier P (debounced Turbo 8 refresh; the browser
  re-fetches as itself) is the sole correctness mechanism. Tier S (render-once
  scrubbed shared broadcast) is a server-cost optimization earned through
  runtime evidence and lost on first divergence. No configuration surface;
  the only switch is the `UPKEEP_DISABLE_REGION_BROADCAST=1` kill switch.
- **Facts and verdicts.** Committed writes become facts (rows, changed
  columns, before/after values where knowable); each dependency evaluates
  enter / leave / in-place / irrelevant under three-valued logic. Irrelevant
  writes cost nothing; churn nets out; unknowable degrades to refresh —
  coarser, never staler.
- **Identity fails closed; freshness fails open; degradation is loud.**

## Landed, in order

1. **Replacement pass** (`118a255..6c1cc19`): old implementation deleted;
   gem at repo top level; RETURNING boot-probe for exact bulk row identity;
   per-member divergence ejection (closed the flag-flip window); Tier S
   auto-detection of top-level partials; platform signals over parallel
   bookkeeping (`after_all_transactions_commit`, `transaction.active_record`
   outcome, `affected_rows` zero-skip, `insert_all` returned pks,
   `write_query?` cross-check); cohort lifecycle (TTL/pruning/claim sweep);
   optimistic locking + indexed cohort-tables join table; real forked-process
   + redis cable test; boot-time cable topology check; scrub-context app
   helpers; pagy Array locals rebuildable; CI matrix with the 7.1 leg as
   version-coupling ledger.
2. **Fact/verdict + complexity pass** (`83d2535..12026a3`): the verdict
   layer; 23 methods over cyclomatic 7 (worst 26) → 0 offenses at
   threshold 10, enforced in CI; savings proven on census-realistic shapes;
   two-browser smoke executing for real (found a redis-6-vs-Action-Cable pin
   and a bodyless fixture; delivery paths were sound).
3. **Closing sequence** (`277b9d0..078614e`): scripted rename
   RefreshSync→Upkeep (dry-run first); v0.3.0 + changelog; CI green both
   legs after real fixes (lockfile CHECKSUMS defect, 7.1 `load_defaults`,
   pool sizing for whole-life leasing); `Upkeep.clock` injectable time
   (claim-window flake pinned); predicate-column cache. Pulse re-synced at
   `59bc2eb4d` (9 proof specs green from cold shell) — now one gem version
   behind again, see Missing.
4. **README/verdict docs + relation round-trip pin** (`8fbe9e9`, `a41efcf`).
5. **Wave 1** (merge `4fe3867`):
   - **SQLGlot binding** — sql-glot-rust v0.10.27 over FFI as a core
     dependency (`Upkeep::SQLGlot`), precompiled-platform gem machinery,
     5-platform native-build workflow, ~55µs full parse+qualify+scope.
     Finding: upstream v0.10.27 SILENTLY TRUNCATES Postgres `#>`/`#>>`
     (tokenizer emits, parser drops, no error) — the old patch is restored
     in the build and pinned by test; an upstream PR is still owed.
   - **Legibility layer** — every `*.upkeep` event classified in one
     exhaustive map (`Upkeep::Legibility::TIERS`; unclassified raises in
     test): liveness-LOST raises in dev/test with app-code frame and fix
     (`UPKEEP_NO_RAISE=1` opt-out); liveness-COARSENED shows in a
     per-request dev summary line; `rails upkeep:report` (+JSON) prints the
     static liveness map. Found two real bugs on arrival (DDL misreported as
     unattributed writes; the Pulse fixture layout silently falling back to
     ERB on Herb compile failure).
6. **Wave 2a — parser precision** (`73e996c`, `4ce199f`), priorities set by
   the Pulse opacity census (docs of record: census in the session log;
   ~52 hot fragment sites, 4 raw-SET sites, 9 string joins, ~180 aggregate
   sites, ~15 JSON-operator sites):
   - Parse-once cache (SHA-256 shape key, 512-entry FIFO, failures cached
     as permanent opaque, 1.9µs hits; missing native lib degrades whole
     feature to pre-parser behavior).
   - Fragment predicates matchable AND verdict-evaluable (three-valued
     tree; functions/casts/JSON ops matchable-only → UNKNOWN → refresh).
   - Raw-SET column extraction (`position = position + 1` reorders now
     column-precise).
   - String-join/alias resolution via scope analysis (physical tables,
     no schema hash needed).
   - Fragment relations Tier S rebuildable when the parse proves a
     self-contained single-table deterministic predicate (pin test flipped
     to capability test, negatives kept).
   - Temporal-literal expiry: capture-day literals stamp cohort expiry at
     next local midnight (`Upkeep.clock`), healing today-baked scopes at
     the boundary instead of never.
   - Unattributed-query attribution: parser extracts tables → conservative
     dependency; liveness-LOST now only for genuinely table-less SQL.
7. **Wave 2b — aggregate value-sensitivity** (`dc6c54c..9bdb22f`):
   calculation doors record (function, aggregated column, grouping columns)
   beside membership predicates; verdicts: enter/leave always refresh,
   in-place refreshes only when changed columns intersect
   aggregated ∪ grouping ∪ predicate columns; count never refreshes on
   in-place; missing info fails toward refresh. Census-shaped capacity
   dashboard proof (`test/aggregate_savings_test.rb`): unrelated-column
   edits now free.

## Documented bounds (final, on principle)

- Entitlement changes not backed by any DB row the viewer's render read
  (time-of-day branching, Ruby constants, thread-locals) heal one debounce
  beat late via the post-broadcast digest backstop. Price of not
  constraining the app's programming model.
- Raw-string SET with an unparseable expression → all-columns coarseness.
- Bulk-write before-values are structurally unknowable → verdicts can't
  prove :leave/irrelevance → conservative refresh (disjoint-SET-columns
  proof excepted).
- 7.1: no `after_all_transactions_commit` → immediate scheduling; a rolled
  back bulk write costs one spurious refresh. Ledgered in CI.

## Missing / next

**Engineering (in priority order):**
1. **Wave 3 — parser-first shadow migration.** Run a parsed-SQL capture
   pipeline beside the Arel walker; log read-set disagreements; benchmark
   gate (~0.02ms/request neighborhood). If clean: delete the walker, the
   read-door catalog, and the completeness audit (attribution becomes total
   by construction). Decided on evidence, not yet started.
2. **Pulse re-sync #2.** The gem grew `path` (legibility) and `expires_at`
   (temporal expiry) cohort columns plus aggregate descriptors since Pulse's
   `59bc2eb4d`; refresh the InstallUpkeep migration, re-run the 9 proof
   specs, exercise `rails upkeep:report` against real pages.
3. **Known small debts:** browser smoke hardcodes the macOS Chrome path
   (Linux CI skips it); assertion totals wobble ±4 across runs
   (timing-dependent retry asserts, cosmetic); predicate-column cache uses a
   30s TTL for cross-process staleness (under-projects → conservative,
   never wrong); wave-2b agent's narrative report never delivered (work
   verified independently; commits + tests are the record).
4. **Still conservative, candidates for later:** polymorphic associations
   (model-mapping, not parsing; 7/10 render on reactive Pulse pages);
   JSONB operator EVALUATION semantics (`@>`, `?|` incl. the bind-`?`
   escaping collision); runtime-interpolated fragments fragment the parse
   cache (cap absorbs it; per-shape normalization would fix it); named-bind
   fragments on 7.2+ (positional order not provable).
5. **Pilot rollout:** deploy to a real environment, watch the legibility
   surfaces under production traffic, measure Tier S promotion rates.

**External actions (user's to take):**
- Push Pulse `feature/refresh-sync` (local only at `59bc2eb4d`).
- Release the gem (0.3.0 tagged nowhere; native-build workflow publishes
  platform gems on tag).
- File upstream: Herb whitespace-trim parity bug
  (`docs/archive/herb-trim-repro.rb`); sql-glot-rust Postgres JSON-path PR —
  now with the stronger finding that v0.10.27 silently truncates
  (`ext/sqlglot_rust/patches/postgres_json_path_operators.patch` +
  `test_postgres_json_path_operators_roundtrip` are the basis).
