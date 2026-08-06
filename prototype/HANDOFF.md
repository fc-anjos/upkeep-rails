# HANDOFF — refresh_sync prototype

For the agent continuing this work. README.md holds the design narrative,
measured results, and per-phase verdicts — read it first; nothing there is
repeated here. This file is everything I know that is NOT in the README and
not obvious from the code: dead ends, version couplings, hunches, seams,
and harness traps.

Worktree state at handoff: three commits (`ff24887` core proof, `b7faab3`
two-tier + leak suite, `b8583bf` origin/persistence/coercion/health), all
suites green: 41 runs, 223 assertions, 0 failures (two seeds).

> **Phase 5 addendum (2026-08-06, gap-closing pass).** All six diagnosed
> phase-4 gaps closed; 81 runs / 550 assertions across 19 suites (see
> README phase 5 for the narrative). What the next agent must know beyond
> the README:
>
> - **New version couplings** (added to §2): `ActiveRecord::AttributeMethods
>   ::Read#_read_attribute` (iteration-identity verification),
>   `ActiveRecord::StatementCache#execute` + ivars `@model`/`@bind_map` +
>   `BindMap#bind` (the statement-cache read door — note the ivar is
>   `@model`, NOT `@klass`, and `execute` takes an `async:` kwarg), herb's
>   attribute-value ERB compilation (`::Herb::Engine.attr`), and
>   turbo-rails `broadcast_action_to(attributes:)`.
> - **Herb rejects whole-attribute ERB** (`<div <%= x %>>`) with a
>   SecurityError; ERB inside an attribute VALUE compiles fine — that is
>   why the dynamic stamp is injected as an ERBContentNode inside
>   HTMLAttributeValueNode children (probed before building).
> - **The pulse_fixture "first delivery baselines every region" assertion
>   was rewritten** — the only pre-existing assertion changed in phase 5,
>   because item 3 abolishes exactly that behavior. Everything else passed
>   unmodified.
> - **Harness traps added**: `RefreshSync.dispatch_interlock` is a test
>   seam (reset to nil in ProofHelpers#setup — leave it that way);
>   row_identity/baseline/delivery_ordering/unbroadcastable tests wipe
>   `Item.unscoped` in their own setup like pulse_fixture does; the
>   read-door audit means ANY new fixture page doing raw SQL reads during
>   capture will refuse registration unless the query is named
>   ("Model Action") — a bare `select_all` in a fixture controller is now
>   a capture-refusal, not a silent pass.
> - **`assert_refreshes`' final broadcast check asserts an exact count**,
>   so tests that mix refreshes and region broadcasts on ONE stream will
>   fight it — surface streams and cohort streams are distinct on purpose.

> **Phase 4 addendum (2026-08-06, integration pass).** Provenance merged
> into the runtime, demotion race closed, region broadcast + Pulse
> hardening landed; 63 runs / 369 assertions across 14 suites, two seeds.
> New version couplings: `ReActionView::Template::Handlers::Herb.call`
> (class-level, reactionview 0.3.0), `ActionView::OutputFlow#get` (yield
> buffer link), `ActionView::Helpers::CacheHelper#cache` +
> `cache_fragment_name` signature (fragment read sets), Turbo's `targets:`
> attribute escaping (tests assert `&#39;`). New harness traps: the pulse
> fixture wipes `Item.unscoped` in ITS OWN setup (ProofHelpers#setup does
> not know the table); combined runs share template caches, so visitor
> changes need `tmp/` template-cache-free reruns; `Capture.last_recording`
> is a test hook, not API. Region-delivery gotchas are in README phase-4
> "Where reality pushed back" — read them before touching
> `broadcast_regions` or the fragment side-entry format (now
> `{"read_set" =>, "node_digests" =>}` — phase-3 side entries are absorbed
> via the `fetch("read_set", stored)` fallback).

---

## 1. Rejected approaches (do not re-walk these)

- **Hooking `ActiveRecord::Persistence::ClassMethods#instantiate`** for
  read-set ids. It parses fine and NEVER fires on Rails 8.1 — every
  materialization path goes through `instantiate_instance_of`. I lost a
  debugging cycle to a hook that was silently dead. See §2.
- **Recording loaded ids inside `Relation#exec_queries`** by iterating the
  returned records. Redundant once `instantiate_instance_of` is hooked
  (double-recorded every row) and it misses `Model.find` entirely. The
  relation hook now records ONLY predicates; ids come from instantiation.
- **Naive before/after benchmarking.** Two attempts produced *negative*
  capture overhead: (1) a separate `/plain_boards` route appended later in
  the route set measured route-matching cost, not capture cost; (2) even
  same-route toggle-based comparison had ordering bias. Only
  order-alternated interleaving (odd iterations captured-first) gave a
  stable ~9% figure. `overhead_bench.rb` embodies this; don't simplify it.
- **Asserting on raw ActionCable test-adapter payloads.** They are
  JSON-encoded strings (`"<turbo-stream..."`); every substring
  assertion must decode first (`ActiveSupport::JSON.decode`). The sentinel
  grep intentionally runs on the ENCODED payload — fine for ASCII
  sentinels, wrong if you ever assert on angle brackets.
- **Guessing the test adapter's ivar as `@broadcasts`.** It is
  `@channels_data` (`actioncable-8.1.3/lib/action_cable/subscription_adapter/test.rb`).
- **Computing the cross-process claim window at dispatch time.** Racy at
  window boundaries (processes dispatch at slightly different wall
  times). The window id is stamped at *schedule* time (`Debouncer#schedule`).
  I considered deriving it from the monotonic clock — wrong, monotonic
  clocks are per-process; wall clock is required for cross-process
  agreement.
- **Evidence keyed by generation number** (`{gen => {viewer => ...}}`).
  Old generations are never read again, and JSON persistence turns both
  key layers into strings (integer viewer ids reload as string keys → the
  same viewer counts as two identities → a surface can self-promote off
  one person). Replaced with current-generation-only, viewer-id-**string**
  keys, cleared on `bump_generation`. If you reintroduce history, keep the
  key normalization.
- **Handling `Arel::Nodes::BindParam` as the equality RHS.** Rails 8.1
  puts a bare `ActiveRecord::Relation::QueryAttribute` there. BindParam
  handling is retained as a fallback branch but is not the live path.
- **Auto-detecting surfaces by hooking partial rendering**
  (`ActionView::PartialRenderer`). Deliberately not attempted: fragile AV
  internals, and locals capture there is murky. The explicit
  `shared_surface` helper was chosen so the promotion machinery could be
  proven in isolation. The real gem may still want the hook — treat it as
  unexplored, not rejected-on-evidence.
- **The coordinator's "one table" for cohorts+promotion.** Rejected with
  reasoning (promotion state is per-surface, shared by many cohorts;
  per-cohort duplication = coherence bugs). It's three tables: cohorts,
  surfaces, claims. Argued in persistence.rb's header comment.
- **Server-side origin-refresh suppression** (tracking "who wrote" and
  skipping their stream). Rejected by design decision relayed from the
  user: origin tab is just another subscriber; only GET-boundary writes
  stamp a request id. Do not reintroduce suppression logic.

## 2. Version-coupling ledger (check each on every Rails upgrade)

| Symbol | Where | Why not public API | Upgrade check |
|---|---|---|---|
| `ActiveRecord::Persistence::ClassMethods#instantiate_instance_of` | hooks.rb `InstantiateObserver` | The public-looking `instantiate` no longer sits on any hot path; there is no supported "record materialized" hook (`after_find` is per-model, notifications give counts not ids) | Boot app, run `proof_test`; if ids stop being recorded, find where `ActiveRecord::Result` rows become objects now |
| `ActiveRecord::Relation#exec_queries` | hooks.rb `RelationObserver` | No public "relation executed" hook with access to the relation object | Same smoke test; watch for load-path bypasses (async queries land elsewhere) |
| `conn.lookup_cast_type(column.sql_type)` | coercion.rb | `lookup_cast_type_from_column` existed for years, removed by 8.1; `ActiveRecord::Type.lookup` needs adapter context | If removed again, `conn.send(:type_map).lookup(sql_type)` worked in probing; a per-model fallback is `Model.type_for_attribute` (needs table→model mapping) |
| `Arel::Nodes::Equality#right` == bare `QueryAttribute` | relation_analysis.rb `literal_value` | Arel node shapes are unversioned internals; 8.1 dropped the BindParam wrapper | The fail-open design absorbs this: a shape change degrades to table-level with reason `unanalyzable_*` — grep instrumentation for those reasons after upgrade, don't wait for bug reports |
| `Arel::Nodes::HomogeneousIn` `#casted_values` / `#type` | relation_analysis.rb | Same | Same |
| `ActiveSupport::CurrentAttributes.clear_all` (NOT `reset_all`) | shared_render.rb | `reset_all` hits `method_missing` on the abstract base and raises | The phase-2 dead-feature incident. `Health#tier_s_dead?` now catches the class of bug; still verify `clear_all` survives |
| `ActiveSupport::CurrentAttributes::CodeGenerator`-generated readers read `@attributes` directly | ambient.rb `CurrentAttributesObserver` | No shared choke point exists; we wrap the `attribute` class-method generator and prepend per-attribute observer readers | If reader codegen changes (e.g. reads via a method), the prepend silently stops observing → ambient CurrentAttributes reads become invisible → Tier P pinning weakens. There is NO test for this specific choke point — write one |
| `ActionDispatch::Request::Session` instance methods (`[]`, `fetch`, `dig`, …) | ambient.rb `SessionObserver` | Public-ish but undocumented surface; new read methods (e.g. a future `slice`) won't be wrapped | Diff `Session.instance_methods(false)` across upgrades |
| Null-session CSRF in bare test apps | test_helper.rb | With `load_defaults 8.0` and no env config, forgery protection defaults to `:null_session` and **silently discards session writes** in integration POSTs | Symptom: viewer resolution returns nil everywhere, promotion unreachable, zero errors. `config.action_controller.allow_forgery_protection = false` |
| `ActionCable::SubscriptionAdapter::Test` `@channels_data` | test_helper `all_broadcast_payloads` | No public "all broadcasts across all streams" API | Trivial to re-find in the adapter source |
| `Turbo::StreamsChannel.broadcast_refresh_to(stream, request_id:)` → `request-id` attr | debouncer.rb default action | Relies on turbo-rails rendering arbitrary attributes into the tag | Assert in origin_test still parses `request-id="..."` |
| `X-Request-Id` response header == `request.request_id` | capture.rb, origin_test | Prototype stamps Rails' request id; REAL Turbo clients compare against `X-Turbo-Request-Id` (their own header, tracked by Turbo JS) | Integration with real browsers must read `X-Turbo-Request-Id` first (capture.rb already prefers it) and confirm Turbo's discard actually fires — never tested against a real browser |
| `ActiveRecord::AttributeMethods::Read#_read_attribute` | hooks.rb `AttributeReadObserver` | The one choke point all generated attribute readers funnel through; no public "attribute read" hook exists | If generated readers stop calling it, iteration-identity verification silently weakens (row targeting keeps working but loses its mismatch detector); grep for `define_method` in attribute_methods/read.rb after upgrades |
| `ActiveRecord::StatementCache#execute(params, connection, async:)` + `@model`, `@bind_map`, `BindMap#bind` | hooks.rb `StatementCacheObserver`, recording.rb `record_statement_cache` | Statement caches bypass `Relation#exec_queries` entirely; the bind map is the only structured predicate source | The ivar is `@model` (NOT `@klass` — cost one debugging cycle). If ivars/signature change, the door silently stops recording and the audit starts flagging `Model Load` queries as unhooked — which is the designed failure mode, loud not stale |
| Herb attribute-value ERB (`::Herb::Engine.attr`) | provenance.rb `Visitor#stamp_element`/`output_node` | The dynamic `data-rs-node` stamp is an ERBContentNode injected into HTMLAttributeValueNode children; herb REJECTS whole-attribute ERB position (SecurityError) | Recompile a stamped fixture and diff bytes; if `Engine.attr` changes escaping, instance stamps change everywhere at once (digest evidence resets — safe, loud) |
| `Turbo::StreamsChannel.broadcast_action_to(attributes:)` | surfaces.rb `generation_stamp` | Arbitrary tag attributes on broadcast turbo-stream tags | origin/delivery_ordering tests parse `data-rs-gen="N"` |

## 3. Unwritten hunches (suspected, not proven)

- **Debouncer threads are never shut down.** Every test's `setup` creates a
  new Debouncer; old worker threads linger in 5s condvar waits, and an old
  thread can still FIRE a pending entry from the previous test after the
  new test cleared the pubsub. I believe the per-test `pubsub.clear` +
  fresh store makes stale fires target streams nobody asserts on — but I
  never proved it, and a rare CI flake with an off-by-one broadcast count
  is most likely this. A `Debouncer#shutdown!` called in teardown is the
  first thing I'd add.
- **`test_refresh_budget_caps_storms` and the cascade test are
  timing-sensitive.** The budget test's "first wave ≤ 8" assertion assumes
  the first tick completes before the 0.40s sleep ends; a loaded CI box
  could see a second tick sneak in. The cascade test's `rounds <= 3` and
  `refreshes_accepted <= 2` depend on drain timing. They passed every run
  here (~10 runs) but I'd call them the two most flake-prone tests.
- **Datetime precision is an open coercion hole.** Only `date` columns are
  tested. JSON serialization of a Time drops sub-second precision; two
  Times differing only in usec cast to unequal values → silent
  under-invalidation for datetime-predicate pages. Decide a truncation
  policy in `Coercion.same?` before anyone uses datetime predicates.
- **SQLite masks Postgres in at least four spots:** (1) the surface-row
  read-modify-write (`hydrate` → mutate → `update!`) is serialized by
  SQLite's file lock; on PG two processes interleave and lose updates —
  needs `SELECT ... FOR UPDATE` or optimistic locking; (2)
  `find_or_create_by!` in `upsert` races on PG (the `rescue
  RecordNotUnique; retry` helps only if the unique index exists); (3)
  `tables_json LIKE '%"cards"%'` is a full scan and also matches a table
  literally named with a quote-substring — fine for a proof, not a
  matcher; (4) boolean/date storage formats differ, and coercion is only
  tested against SQLite's.
- **`RefreshSync.stats` is a bare `Hash.new(0)` incremented from three
  threads.** GVL makes `+= 1` effectively atomic today; JRuby/TruffleRuby
  or future YJIT changes could drop counts. Tests assert on stats.
- **The raw-SQL regex misses real shapes**: `WITH ... UPDATE`, multi-statement
  strings, `INSERT ... ON CONFLICT` is caught but `MERGE` isn't, and
  `exec_update` with a custom name slips the name filter. Every miss is a
  silent under-invalidation on a raw-SQL write.
- **`respond_to?(:current_user)` scrub-divergence relies on the scrub
  controller having NO app helpers.** In a real app, helpers are often
  globally included (`helper :all` legacy, ApplicationHelper); a scrub
  controller inheriting from `ApplicationController`'s view context would
  see `current_user` defined and possibly *raising* or returning nil —
  changing scrubbed digests. The scrub renderer must be built bare
  (inherit `ActionController::Base`, include nothing) and that constraint
  is currently only enforced by the test app's structure.
- **`previously_new_record?` / upsert paths untested**: `insert_all`,
  `upsert_all` bypass callbacks entirely (they're caught only by the raw
  SQL regex, as table-level), and `touch` is untested.
- **Cohort rows grow forever** (one per captured GET, no pruning;
  `heartbeat_at` written once, never updated). Fine in tests that wipe;
  unbounded in any real run longer than minutes.

## 4. Productionization seams

- **Real pub/sub**: delivery already flows through
  `Turbo::StreamsChannel.broadcast_*` → whatever Action Cable adapter is
  configured. That is the ONLY cross-process delivery mechanism; nothing
  else needs replacing for Redis/PG pub-sub. What is missing is
  *cache-invalidation* pub/sub for `ActiveRecordStore`'s watch set
  (currently: TTL + re-check-on-miss, one query per unmatched hot write).
- **Claim sweeping**: `DbClaimer` inserts rows forever. Sweep
  `refresh_sync_claims WHERE created_at < now - 5 * window` — cheapest as
  an opportunistic delete inside the dispatcher tick (upkeep's
  `trim_opportunistically` pattern from the main codebase is the model).
- **Activation handshake**: attach in `Capture#_refresh_sync_capture`
  where the cohort registers and the header is set. The main codebase's
  `lib/upkeep/rails/cable/` (CohortToken HMAC + `ViewerIdentity`) drops in
  here: registration writes `activated_at: nil`, the channel's
  `subscribed` verifies the token and flips activation, and
  `ActiveRecordStore#matching_cohorts`/`watch_set` gain
  `WHERE activated_at IS NOT NULL`. The prototype's `Viewer` +
  `viewer_resolver` is the unauthenticated stand-in for `ViewerIdentity` —
  same seam.
- **Keep as-is** (semantics proven, code small): `ReadSet` + `Coercion`,
  the `Surface` state machine (with the §6 stale-object fix), `Debouncer`
  semantics (request-id merge, budget+jitter, schedule-time claim
  windows), `Ambient` choke points + `unobserved`, `Health`.
- **Throwaway / redesign before production**: `MemoryStore` (test double),
  the `tables_json LIKE` matcher (needs a real reverse index — but resist
  rebuilding upkeep's 4-table index; a `(table, cohort_id)` join table is
  enough), `Descriptor` serialization (`where_values_hash` faithfulness is
  a heuristic; the real gem should serialize its own predicate IR, which
  `RelationAnalysis` already produces), the watch cache, `Health`'s
  hardcoded thresholds, everything in `test_helper.rb`.

## 5. Test-suite map

| File | Proves | Class |
|---|---|---|
| proof_test.rb | Phase-1 core: precision, predicate inserts, coalescing, bulk fallback, zero-cohort gating, fan-out | **Load-bearing regression guard** — run on any lib change |
| tier_test.rb | State machine transitions, deploy-key isolation, generation false-pin guard, render-failure demotion, refresh budget | Load-bearing; `test_refresh_budget_caps_storms` is timing-sensitive (§3) |
| leak_test.rb | Adversarial promotion refusals + THE window test (`test_per_user_flag_flip_window_exists_then_heals` doubles as the design's honesty documentation) | Load-bearing; do not "fix" the window test if it starts failing — that means the window semantics changed, which is a design event |
| origin_test.rb | POST origin gets own refresh; GET-write stamping; cascade termination | Load-bearing; cascade test is the other timing-sensitive one |
| persistence_test.rb | Restart survival, cross-process routing/coalescing/promotion/demotion | Load-bearing; **process-global-state-dependent** (swaps `RefreshSync.store/registry/debouncer` — see §6) |
| coercion_test.rb | JSON-roundtrip matching both directions, unit + end-to-end | Load-bearing, fast, no timing |
| health_test.rb | Lifecycle events; dead-Tier-S signal recreating the reset_all incident | Load-bearing; subscribes to global notifications — a leaked subscriber from a crashed test could double-count (each test detaches in ensure) |
| demotion_race_test.rb | Cross-process demotion vs pending broadcast; the narrowed post-render window via `dispatch_interlock` | Load-bearing; second test verified to fail against pre-fix ordering |
| row_identity_test.rb | Row update -> instance replace; destroy -> remove; insert -> whole-region fallback; skip-loop unsoundness voids targeting; DOM instance stamps | Load-bearing for item-1 semantics |
| baseline_test.rb | First write sends only the changed region; stale-baseline cohort gets the cumulative diff on its own stream | Load-bearing for per-cohort baselines |
| delivery_ordering_test.rb | Generation stamps on pages + broadcasts; SimViewer rejects the stale in-flight morph | SimViewer is the reference client contract |
| read_doors_test.rb | calculate/pluck/exists?/statement-cache doors; audit degrade + refuse paths | Load-bearing; also guards the audit's false-positive direction (hooked doors emit no events) |
| unbroadcastable_region_test.rb | Bare in-flow cache block reported via region_unbroadcastable; refresh covers it | Signal-only semantics — promotion must still succeed |
| pulse_fixture_test.rb (phase 5) | First-write assertion REWRITTEN to baseline-from-capture semantics | The one modified pre-existing assertion |
| overhead_bench.rb / herd_bench.rb | Measurement scripts (README numbers) | Scaffolding — not regression tests, not in the combined run; NOTE: phase-5 hooks (attribute reads, read doors) postdate the README phase-1 overhead numbers — re-measure before quoting them |
| debug_readset.rb | Dumps a captured read set | Scratch tool, safe to delete |

Order-dependence: none observed across two seeds, BUT all suites share one
Rails app boot (test_helper is process-global) and rely on `setup` fully
resetting `RefreshSync.*` globals. Any test that forgets to restore
`renderer_class` / `require_role_diversity` / `deploy_key` poisons
followers — the existing tests restore in `ensure`; keep that discipline.

## 6. Harness gotchas (false-confidence traps)

- **`in_process` swaps globals only for the block, but debouncer threads
  outlive the block.** A scheduled action fires LATER on whichever
  debouncer instance it was scheduled on — that part is faithful. NOT
  faithful: anything the fired action reads from `RefreshSync.*` at
  dispatch time sees whatever the LAST `in_process` left installed. The
  simulation is honest only while actions touch state captured in their
  closure. This is also how I found (while writing this document) the
  genuine bug in §"realized below".
- **The fake processes share one Ruby process**: class-level caches
  (`Coercion` types, AR schema cache, template caches) are shared even
  though real processes would each have their own. A cross-"process" test
  passing here can still fail in real multi-process from cold caches.
- **Sentinel grep** (`assert_no_sentinel_broadcast`) greps the
  JSON-ENCODED payloads of the test adapter across ALL streams. It only
  sees what went through `ActionCable.server.pubsub` — anything delivered
  by a hypothetical future transport bypassing the cable is invisible to
  it. It is also only as good as sentinel placement: session secret +
  user names carry sentinels; card titles/board names do NOT — a leak of
  non-sentinel viewer data would pass. Extend sentinels when adding
  fixtures.
- **Viewers/roles are simulated thinly**: `session_for(user)` POSTs to a
  test-only login that stuffs `session[:user_id]`; `viewer_resolver`
  re-reads it per capture. Role diversity means "the `role` string column
  differs". There is no permissions system — the admin badge tests
  *simulate* privilege via `role == "admin"`. Don't conclude RBAC
  interactions work.
- **`drain_debounce` is `sleep WINDOW + 0.25`** — it does not verify the
  dispatcher actually ticked. On a very loaded machine assertions after a
  single drain may observe pre-tick state. `assert_refreshes` polls with
  a deadline and is the safer pattern; prefer it.
- **One in-memory Rails app for everything**: routes appended by
  overhead_bench persist for the rest of that process's tests
  (reload_routes! rebuilds the set). Adding routes in a test file affects
  suites required after it in combined runs.

---

## 7. Integration surface (read this before wiring Pulse)

What a real app installs, what config exists, and what the gem hooks at
boot — the seam inventory for the next phase. Everything here exists in
the prototype today unless marked (gap).

**Boot (railtie territory — `RefreshSync.install!` plus provenance):**

- `Hooks.install!` prepends: `Relation#exec_queries`, `Relation`
  read doors (`calculate`/`pluck`/`exists?`), `Relation#update_all`/
  `#delete_all`, `StatementCache#execute`,
  `Base.instantiate_instance_of` (singleton), `Base#_read_attribute`,
  includes the `after_commit` write observer, and subscribes to
  `sql.active_record` twice (raw-write safety net; read-door audit).
- `Ambient.install!` prepends session/cookie-jar readers and wraps the
  `CurrentAttributes.attribute` generator.
- `FragmentCache.install!` prepends the `cache` view helper (on_load
  :action_view).
- `Provenance.install!` registers the compile-time visitor on
  `ReActionView.config.transform_visitors`, swaps the `:erb` template
  handler for the gating `Provenance::Handler`, and prepends
  `ActionView::OutputFlow#get`. Requires the reactionview + herb gems.
- An `around_perform` on ActiveJob suppresses cohort registration in jobs.
- Persistence: `ActiveRecordStore.setup!` creates the three tables
  (cohorts — now with `baselines_json`; surfaces — now with a `status`
  column + `dispatched_at` for the dispatch CAS; claims). A real app ships
  these as a migration instead.

**Per-app configuration (all on `RefreshSync.` unless noted):**

- `store` / `registry` / `debouncer` — production:
  `ActiveRecordStore` + `ActiveRecordSurfaceRegistry` + `Debouncer` with
  `claimer: DbClaimer.new`, window/budget/jitter to taste.
- `viewer_resolver` (->(request) -> Viewer(id:, role:) | nil) — the
  authenticated-identity seam; drop-in point for the main codebase's
  `ViewerIdentity`.
- `renderer_class` — the scrub renderer; MUST be a bare
  `ActionController::Base` subclass with the app's view paths and NO app
  helpers (see §3 note on `respond_to?(:current_user)`).
- `identity_columns` (default `%w[user_id]`), `require_role_diversity`,
  `deploy_key` (cache-bust per deploy), `payload_limit`, `ignored_tables`.
- `Provenance.instrument_paths` / `stamp_paths` — which view roots compile
  through Herb and which additionally get `data-rs-node` stamps. For Pulse:
  point both at `app/views`, then narrow if compile cost matters.
- `Capture.enabled` — global kill switch.

**Per-controller:** `include RefreshSync::Capture` + `refresh_sync`
(around_action; registers cohorts only for registrable browser HTML GETs).
**Per-view:** `shared_surface name, partial:, **locals` for Tier S
candidates (auto-detection deliberately unexplored, §1).

**What the app's client must do (all currently simulated in tests — the
REAL client is the biggest remaining integration gap):**

- Subscribe each page to its cohort stream (`X-RefreshSync-Stream`) and
  its surfaces' streams; apply refresh/replace/remove stream actions
  (Turbo does this natively once subscribed).
- The ordering contract: track `X-RefreshSync-Generation` from GET
  responses and `data-rs-gen` from stream tags; never apply a full-page
  morph older than the newest applied region update — discard + re-fetch
  instead (delivery_ordering_test's SimViewer is the reference
  implementation, ~20 lines).
- Turbo's native request-id discard for GET-boundary writes
  (`X-Turbo-Request-Id`, §2 last row).

**Known integration gaps (loud, not hidden):** no reconnect-triggered
refresh (a viewer that misses a delivery on a never-changing region is
stale until navigation — README phase 5 "Baseline drift"); no cohort/claim
pruning (§3); the activation handshake seam (§4) is still the
unauthenticated stand-in; ViewComponent compatibility unprobed
(spike/FINDINGS §4).

---

## Realized while writing this (changes a phase-3 conclusion)

> **STATUS (phase 5): CLOSED as far as it can be.** The post-render check
> is now an atomic store-side compare-and-set on the surface row's status
> column (`UPDATE ... WHERE status IN ('shared','region_shared')`); a
> demotion persisted at any point before the claim always wins, and the
> narrowed-window regression (`dispatch_interlock` seam) fails against the
> pre-fix read-then-act ordering. HONEST CORRECTION of the phase-4 note:
> "a store-side lock would close it fully" was too optimistic — a demotion
> can still commit while the Turbo transport call is in flight, and strict
> exclusion would mean holding a DB lock across a network write (SQLite
> cannot even express FOR UPDATE). The guarantee is claim + converge:
> demotion always schedules cohort refreshes after its commit, so the
> at-most-one broadcast that slips into the transport window is
> immediately superseded.

**Cross-process demotion does NOT cancel the other process's pending Tier S
broadcast — and the scheduled broadcast closure holds a STALE surface
object.** `report_change` schedules `{ surface.broadcast! }` with the
hydrated `PersistedSurface` captured in the closure. If process A demotes
(row → `:personal`, A's `debouncer.cancel` only clears A's queue) while
process B has that entry pending, B's dispatcher later calls `broadcast!`
on an object whose in-memory `@status` is still `:shared` → the guard
passes → **a shared broadcast can fire after demotion**. The phase-3
persistence test missed it because no broadcast was pending in the other
process at demotion time. My phase-3 claim that "promotion-state coherence
is trivially correct because every lookup rehydrates" is therefore too
strong: it is correct for *lookups*, not for *already-scheduled actions*.
Fix for the next agent: `broadcast!` must re-load status from the store at
dispatch time (schedule the surface KEY, hydrate inside the action), and
ideally re-check after the render, before the `Turbo::StreamsChannel`
call. Until then, treat the cross-process demotion→broadcast race as an
open correctness hole in Tier S.
