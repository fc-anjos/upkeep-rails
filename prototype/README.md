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

---

# Phase 2: Two-tier delivery, leak hunting, herd economics (2026-08-06)

Pure refresh delivery has a scale cliff (one write to a page with N viewers
= N full re-GETs), so the design gained a second tier. **Tier P
(personalized, default): debounced refresh. Tier S (shared, earned): one
scrubbed render broadcast.** Identity fails closed; freshness fails open.

## Test results (verbatim)

Combined run of all three suites in one process:

    26 runs, 148 assertions, 0 failures, 0 errors, 0 skips

(proof_test 10 runs / tier_test 10 runs / leak_test 6 runs; plus
herd_bench and overhead_bench as measurement scripts.)

LOC delta: lib/ 486 -> 885 (+399 for the entire two-tier machinery);
test tree (rb + erb views) 823 lines.

## Promotion state machine (as implemented, per surface name x deploy key)

    :observing  (Tier P) --ambient session/cookie/CurrentAttributes read--> :personal (terminal)
                         --identity-column predicate in read set---------> :personal
                         --unrefreshable locals (non-Relation dynamics)--> :personal
                         --digest divergence across viewers, same gen----> :personal
                         --scrubbed-render digest != viewers' digest-----> :personal
                         --scrubbed render raises----------------------->  :personal
                         --(>=2 identities AND >=2 roles, same generation,
                            identical digests, scrubbed render matches)--> :shared
    :shared     (Tier S) --scrubbed render raises at broadcast----------->  :personal (+drop broadcast, +refresh cohorts)
                         --viewer digest != other viewer, same gen-------->  :personal (demote, +refresh)
                         --viewer digest != last broadcast, same gen------>  :personal (demote, +refresh)
    :personal   terminal for the deploy key; new deploy key restarts at :observing

Write generations advance for *observing* surfaces too — comparing digests
from before and after a data change would otherwise produce false pins.

## Where the leak suite / harness beat the machinery (unsanitized)

1. **`CurrentAttributes.reset_all` does not exist in Rails 8.1** (only
   `clear_all`). Until fixed, *every* scrubbed render raised and every
   promotion silently pinned `:scrubbed_render_error` — Tier S never
   engaged at all. Notable: the bug was invisible because the system
   fails closed; nothing leaked, everything just quietly stayed Tier P.
   Fail-closed made a correctness bug look like conservatism.
2. **Null-session CSRF protection silently swallowed login writes** in the
   harness; every viewer resolved as anonymous, and since unauthenticated
   viewers never count as evidence, promotion was unreachable. Same
   pattern: the failure mode of broken identity plumbing is
   over-conservatism, not leakage.
3. **Cross-write digest comparison** (design hole found while writing the
   suite, encoded as `test_write_between_viewers_does_not_false_pin`):
   without generation bumps on observing surfaces, any write landing
   between two viewers' visits reads as identity divergence and falsely
   pins the surface forever.
4. **Thread.current smuggling with equal values for all viewers** defeats
   both choke points and viewer-digest comparison. It is caught only
   because the scrubbed render runs on a fresh thread, where the smuggled
   state is absent — that made "scrub = fresh thread" a load-bearing
   security property, not an implementation convenience.

## The residual window (cannot be closed by runtime evidence)

`test_per_user_flag_flip_window_exists_then_heals` demonstrates it:
promotion evidence was genuinely clean (two identities, two roles, byte-
identical, scrubbed-verified) because *nobody* had the per-user flag at
promotion time. The flag then flips for one subscribed viewer; the next
write broadcasts HTML that is wrong for that viewer. The system heals at
that viewer's next full GET (`:post_broadcast_divergence` demotion +
refresh), but every broadcast between flip and next-GET is inside the
window. Two honest bounds on the damage:
- **It is degradation, not credential leakage**: the scrubbed render runs
  anonymous, so it can never *emit* privileged content (asserted by
  sentinel grep over every broadcast payload in every leak test). The
  window under-serves privileged viewers; it does not over-share.
- The window's length is bounded by the affected viewer's own next
  navigation, and role-diversity promotion narrows entry into it to
  attributes outside the role taxonomy.

## Herd economics (measured, N viewers of one shared page per write)

    per full GET (Tier P unit):        1.924 ms
    one scrubbed render (Tier S base): 0.405 ms
    per broadcast transmit (approx):   0.008 ms

    N       Tier P (ms)      Tier S (ms)   ratio
    10          52.3             0.49      108x
    100        192.4             1.21      159x
    500        962.1*            4.43      217x     (*extrapolated linearly)

Crossover: Tier S is cheaper from N = 1. Caveats: Tier P measured as N
sequential in-process GETs (real herds add connection/queue overhead, so
this favors Tier P); Tier S per-subscriber transmit approximates the
pubsub write only, not per-socket writes (favors Tier S at large N).
The two-orders-of-magnitude gap at N>=100 survives both caveats.

Tier P also gained a **global refresh budget with jitter**
(`Debouncer refresh_budget:`): a table-level write burst to 24 cohorts
dispatched at most 8 refreshes in the first window and drained the rest
across jittered windows (asserted in `test_refresh_budget_caps_storms`).

## Where two-tier was more complicated than the argument claimed

1. **"Digest divergence demotes" needs a generation clock.** Digests are
   only comparable between writes; the design sentence omitted a whole
   bookkeeping dimension (evidence generations, bumped by covering writes
   even while observing).
2. **Steady-state divergence detection is asymmetric.** Viewer-vs-viewer
   and viewer-vs-last-broadcast comparisons are both needed; last-broadcast
   comparison is only valid in the same generation, which is why demotion
   after the flag-flip happens at the *next* GET, not at broadcast time —
   the window is structural, not an implementation gap.
3. **Locals refreshability is a promotion criterion.** Tier S re-renders
   with captured locals; only AR Relations re-query at broadcast time.
   A captured integer (a count, a total) is silently stale — the
   prototype pins surfaces with non-Relation dynamic locals as
   unrefreshable rather than broadcasting stale numbers.
4. **The scrub context is a contract, not a flag**: fresh thread + bare
   renderer controller + cleared CurrentAttributes + no session. Partials
   that call controller helpers (`current_user`) raise in that context —
   which is the correct outcome (demotion), but means Tier S partials
   must be written against an explicit "no ambient anything" interface.

## Verdict (phase 2)

The two-tier design holds with one honest asterisk. Promotion-by-runtime-
evidence + scrubbed rendering is buildable in ~400 LOC and defeated every
disguised-personalization page in the adversarial suite — except the
per-user-attribute flip, which is detectable only after one wrong-for-one-
viewer broadcast. That residual window is real, bounded, heals itself,
and cannot emit privileged content; closing it entirely would require
write-time knowledge of every identity-conditional branch (i.e., static
analysis of views — the road back to the machinery this redesign exists
to avoid). Ship Tier S behind per-surface opt-in if that window is
unacceptable for a given page.

---

# Phase 3: Origin model, durability, cross-process, coercion, health (2026-08-06)

Design decision (supersedes the earlier self-refresh note): **the origin tab
is just another subscriber.** Writes are POST + `head :no_content`; the
broadcast is the single source of UI truth for everyone including the tab
that wrote. No conditional suppression. Request-id stamping survives for one
purpose only: a write committed DURING a GET is stamped with that GET's
request id so Turbo 8's *native client-side* discard breaks the
GET -> write -> refresh -> GET loop (view counters, mark-as-read). Redundant
refresh on a POST origin tab is accepted waste (morph no-op).

## Test results (verbatim)

All seven suites in one process (two seeds):

    41 runs, 223 assertions, 0 failures, 0 errors, 0 skips

LOC: lib/ 885 -> 1,280 (+395: persistence 174, coercion 40, health 38,
origin/request-id ~20, serialization + evidence-generation rework in
surfaces/read_set the rest).

## What was built

1. **Origin model + loop guard.** `report_change` reads the active
   Recording's request id (present only for GET-boundary writes) and the
   dispatcher stamps it on the refresh tag; two coalesced writes with
   different origins drop the stamp (suppressing would hide the other
   write). Client discard is Turbo's native behavior — the test simulates
   it. The cascade test (write-on-read inbox page, refresh-triggered GETs
   that also write) reaches a fixed point in <=3 rounds; every viewer
   accepts <=1 refresh per write generation.
2. **Durable cohorts + cross-process.** `ActiveRecordStore` (cohorts:
   stream, read-set JSON, surface names, tables, deploy key, heartbeat),
   `ActiveRecordSurfaceRegistry` (promotion state rehydrated per lookup,
   persisted per mutation), `DbClaimer` (unique (key, window) row; the
   process that inserts first broadcasts). Proven: cohorts survive a
   simulated restart; a write in process A refreshes a cohort registered by
   process B; rapid writes in BOTH processes within one window produce
   exactly 1 refresh (claims_lost >= 1); promotion built from evidence on
   two processes; divergence seen by A demotes for B.
3. **Type coercion.** All read-set matching compares through the column's
   ActiveRecord cast type (`lookup_cast_type(column.sql_type)` — the
   Rails-8.1 API; `lookup_cast_type_from_column` is gone). "5" == 5 ids,
   JSON-reloaded "2026-01-01" == Date, UUID strings; false-positive
   direction asserted (distinct dates/ids/uuids never blur).
4. **Tier S health.** `ActiveSupport::Notifications` events
   (`surface_observed/promoted/pinned/demoted/broadcast_sent/
   scrubbed_render_failed` + reasons) and a `Health` monitor whose
   `tier_s_dead?` fires when scrubbed renders keep failing and nothing
   promotes — the exact signature of phase 2's `reset_all` dead-feature
   incident, now recreated in a test and caught.

## What the cross-process simulation revealed

- **The claim window must be computed at schedule time, not dispatch
  time.** Two processes dispatch at slightly different wall-clock moments;
  claiming by dispatch time makes the dedupe window racy at boundaries.
  Stamping the window id when the entry is created makes both processes
  agree on which window a write belongs to. Writes that genuinely straddle
  a window boundary still produce 2 refreshes — accepted (refresh is
  idempotent), documented.
- **Promotion-state coherence is trivially correct only because every
  lookup rehydrates from the row.** Any process-local caching of surface
  state reintroduces the demote-lag problem (A demotes, B broadcasts from
  a stale :shared). The prototype's "no cache, read the row every time" is
  correct but hits the DB per surface lookup per request.
- **Evidence had to move to viewer-id-keyed, current-generation-only
  storage.** JSON round-trips turn integer viewer ids into string keys;
  without normalization, the same viewer re-observing after a reload
  counts as a second identity and can self-promote a surface. (Caught by
  reasoning during the rewrite, then covered by the cross-process
  promotion test.)
- **What shared-SQLite papers over for production:** (1) there is no push
  signal between processes — B's dispatcher acts only on writes B itself
  performs; delivery crosses processes because the *cable* is shared, and
  a real deployment needs the same guarantee from its Action Cable adapter
  (Redis/Postgres pub-sub), not from the store; (2) SQLite's file lock
  serializes what Postgres would interleave — the registry's
  read-modify-write on surface rows needs `SELECT ... FOR UPDATE` (or
  optimistic locking) on a real DB, and the claim insert relies on a
  unique index either way; (3) claim rows are never garbage-collected here
  (production: TTL sweep); (4) the watch-set cache re-checks the DB on
  every miss, which is correct but means unmatched hot writes each cost a
  query — production wants pub/sub cache invalidation or a bloom filter;
  (5) `heartbeat_at` exists but nothing prunes dead cohorts yet.

## Cracks found in "the origin tab is just another subscriber"

One, minor and structural: when a write commits during a GET, the cohort
that GET is about to register does not exist yet at match time, so the
origin's own brand-new cohort receives nothing for its own write — fine
(its response already reflects the write) — but any OLDER cohort belonging
to the same browser tab (from its previous page) does receive a stamped
refresh addressed to a page the tab already left. Turbo discards it only
if the tab's last request id matches — it does, since the stamp came from
that tab's own GET. So the model holds, but only because the stamp is
per-tab-request, not per-write: the request-id mechanism is load-bearing
for exactly this edge. Coalescing weakens it deliberately: mixed-origin
writes in one window drop the stamp and the origin tab eats one redundant
morph no-op — accepted waste, asserted in tests.

## Verdict (phase 3)

All four features landed without disturbing the phase-1/2 suites (41/41
across two seeds). The origin model is simpler than suppression logic and
survived its adversarial cascade; durability and cross-process coalescing
work over a plain relational store with one unique index doing the heavy
lifting; coercion closes the serialization under-invalidation hole both
ways; and fail-closed is now observable instead of silent.

---

# Phase 4: Provenance integration, region broadcast, Pulse hardening (2026-08-06)

The integration pass: the ReActionView/Herb provenance spike merged into the
runtime, the cross-process demotion race closed, and the four Pulse-survey
hardening items landed — capped by the full region-broadcast loop.

## Test results (verbatim)

All fourteen suites in one process (two seeds):

    63 runs, 369 assertions, 0 failures, 0 errors, 0 skips

LOC: lib/ 1,280 -> 2,207 (+927: provenance 383, region/evidence rework in
surfaces ~260, fragment cache 78, guards/ignore/persistence/read-set the rest).

## What was built

1. **Demotion race CLOSED.** Broadcasts are scheduled by surface KEY and
   rehydrated through the scheduling process's registry at dispatch, with a
   second store read between the scrubbed render and the transport call.
   The regression test reproduces the stale-closure broadcast pre-fix.
2. **Provenance in the runtime.** Templates under instrumented view paths
   compile through Herb with the node-bracketing visitor (byte-identical
   output; every pre-existing suite passes unmodified). Read-set entries
   carry structural node addresses; cross-template containment uses
   explicit buffer links (render boundary + OutputFlow#get at yield) —
   the spike's substring embedding did not ship.
3. **Per-node evidence and region promotion.** Cross-viewer divergence that
   localizes to islands with a stamped byte-shared remainder records
   `personal_nodes` instead of pinning, and promotes to `:region_shared`.
   Fully-shared surfaces with stamped nodes also deliver as targeted
   replaces. Cohort routing skips refresh only when every matched node
   dependency lies inside a broadcastable region AND no controller-level
   (node-less) dependency matches — otherwise the refresh rides along.
4. **Fragment-cache read sets.** A cache block stores its read-set slice
   AND its node digests beside the fragment; hits replay both. An orphaned
   fragment (side entry evicted) is expired and recaptured — never a warm
   fragment without its dependencies.
5. **Ignore list + activation guard + payload limit.** Infrastructure
   tables produce no change events (loud misuse warning when an active
   cohort depends on one); cohorts register only for genuine browser HTML
   requests (job-context integration sessions, x-llm, XHR excluded — write
   capture stays global); oversized Tier S payloads degrade that delivery
   to a refresh with a `payload_limit_degrade` event.

## The Pulse fixture (end-to-end)

Personalized layout chrome + per-viewer tag INSIDE the shared partial +
Discard default scope + ordered LIMIT list + cached aggregate fragment.
Proven: region promotion with the viewer tag as a recorded island; a
sprint-reorder `update_all` arriving as ONE scrubbed render broadcast as
targeted `[data-rs-node=...]` replaces with ZERO per-viewer refetches; a
controller-pinned cohort correctly getting refresh + region broadcast
together; discarded-row writes precisely ignored; cache hits preserving
both dependencies and node evidence; sentinel grep clean throughout.

## Delivery-ordering invariant (chosen, documented)

Every delivered artifact — a refresh-triggered GET response or a region
replace — renders DB-current state at its own render time; per-stream
ordering is Action Cable's; debouncing yields at most one artifact per
stream per window. A cohort is exempted from refresh ONLY when the region
broadcast fully covers the change, so no viewer ever depends on applying a
region update to learn about a change the region doesn't carry. The
transient interleave (refresh fetch in flight while a replace arrives)
self-heals because both artifacts are DB-current at render.

## Where reality pushed back (findings)

1. **Region granularity is element granularity.** A cache block (or any
   non-element node) is broadcastable only when enclosed in a byte-shared
   element; the fixture's total had to be wrapped in a div. Not authoring —
   but a real gem should surface "this dependency has no enclosing
   broadcastable element" in instrumentation.
2. **Warm fragments erase node evidence** — hits render no nodes, so
   digests are replayed from the side entry (valid: cached bytes are
   capture-time bytes). Without this, the second viewer falsely diverges
   on every cached region.
3. **Loop-body elements share one address** — every `<li>` carries the same
   `data-rs-node`. Harmless (containment excludes them from targeting) but
   per-instance identity is still needed before regions inside loops can
   be targeted individually.
4. **`Relation#count`/`maximum` are invisible to capture** (calculations
   bypass `exec_queries`). The fixture covers count-staleness transitively
   (same-table predicates) and via key-rotated fragments; a real gem must
   hook `calculate` — the old upkeep's "Track Active Record calculations"
   commit exists for exactly this reason. *(Closed in phase 5.)*
5. **First region delivery baselines every region** (no previous digests),
   so it sends all regions once; steady-state sends only changed ones.
   *(Closed in phase 5: baselines seed from capture.)*

---

# Phase 5: Row identity, per-cohort baselines, read-door audit, ordering (2026-08-06)

The six diagnosed gaps from the phase-4 review, closed: per-iteration node
identity, complete read-door coverage with a completeness audit,
baseline-from-capture, the dispatch-time race, unbroadcastable-region
detection, and the delivery-ordering invariant as a mechanism.

## Test results (verbatim)

All nineteen suites, one process each:

    81 runs, 550 assertions, 0 failures, 0 errors, 0 skips

(activation_guard 4 / baseline 2 / coercion 5 / delivery_ordering 2 /
demotion_race 2 / fragment_cache 2 / health 3 / ignore_list 3 / leak 6 /
origin 3 / payload_limit 2 / persistence 4 / proof 10 / provenance 3 /
pulse_fixture 7 / read_doors 7 / row_identity 5 / tier 10 /
unbroadcastable_region 1. Assertion totals vary by a few between runs:
several tests assert per delivered payload, and payload counts are
timing-dependent.)

LOC: lib/ 2,207 -> 2,803 (+596); test tree (rb + erb) 2,499 lines.

## What was built

1. **Per-iteration node identity.** A loop-body node is traced — and
   DOM-stamped, the `data-rs-node` value became a render-time expression —
   as `address@table:id`: the n-th entry of a child address binds to the
   n-th record its parent node materialized (the collection load lands on
   the loop node, in result order, before the first iteration renders).
   A one-row update travels as ONE row-targeted replace; a removed row as
   one `remove`; an inserted row falls back to a whole-list-region replace
   BY DESIGN — digest evidence proves which rows exist, not where a new
   row sits relative to the viewer's DOM, and a wrong position is
   corruption while a whole-region replace is merely coarser. Identity
   fails closed on three runtime signals (attribute reads of a different
   row inside the instance window; entry counts disagreeing with the
   loaded id count; instance re-entry): the base collapses to an
   `__unsound__` digest marker and delivery reverts to whole-region.
2. **Read doors + completeness audit.** `calculate`, `pluck` (covers
   `pick`/`ids`) and `exists?` hooked at the Relation level;
   `StatementCache#execute` hooked with its bind map as the structured
   predicate — closing the nil-result hole (a cached `find_by` that found
   nothing now records the predicate, so the row's later INSERT matches).
   Every door wraps execution in an accounting window; a `sql.active_record`
   SELECT during capture outside any window is an unhooked read door:
   attributable ones (AR's "Model Action" name convention) degrade to a
   loud table-level dependency, unattributable ones REFUSE the capture
   (no cohort, loud `capture_refused` event) — a read set with a silent
   hole is a stale-page lie, so no registration is better than a wrong one.
3. **Baseline-from-capture, per cohort.** Cohorts store a region-digest
   baseline seeded from their own capture render (digests already existed
   as evidence), diffed per cohort at each broadcast, advanced per
   delivery. Identical diffs group into one payload on the shared surface
   stream; divergent baselines deliver on cohort streams. The first write
   after registration now sends only the changed row/region.
4. **Dispatch race closed with a store-side CAS.** Surface status is
   duplicated into its own column; the final pre-transport check is one
   atomic `UPDATE ... WHERE status IN ('shared','region_shared')`. A
   demotion persisted before the claim always wins (regression test drives
   a demotion into the microsecond window via a dispatch interlock seam and
   was verified to fail against the pre-fix read-then-act ordering).
5. **Unbroadcastable-region detection.** Promotion emits
   `region_unbroadcastable` (reason, node addresses, template file via a
   compile-time digest→file registry) for byte-shared content with no
   enclosing stamped element — the bare in-flow cache block case. A signal
   for operators, never a template-change request: refresh covers it.
6. **Delivery-ordering invariant as a mechanism.** Capture responses carry
   `X-RefreshSync-Generation` (per-surface write generation at render
   time); every Tier S tag carries `data-rs-gen`. Client contract: apply a
   full-page morph only when its generation >= the newest applied region
   update; otherwise discard and re-fetch. The interleaving the convention
   previously survived by luck — a GET rendered pre-write whose morph lands
   after a newer region update, silently rolling it back with nothing
   pending — is reproduced with a simulated client (same precedent as
   origin_test's simulated Turbo discard).

## Baseline drift (what protects correctness)

Server-side, a stale cohort baseline cannot corrupt: payloads are full
idempotent region/row content, never deltas, so a stale baseline only makes
the next diff LARGER (asserted: a cohort with a reverted baseline receives
the cumulative diff on its own stream). Client-side, a viewer that missed a
delivery converges at the next change to that region — and for a region
that never changes again, only at its next full GET. The refresh path that
gets the viewer there: any uncovered write to the page schedules one, and
the generation mechanism forces a re-fetch whenever a stale morph meets a
newer applied update. A missed delivery on a page that never changes again
and never re-navigates stays stale — that residual is documented, not
hidden (production should add reconnect-triggered refresh; Action Cable
reports disconnects to the client).

## Where reality pushed back (phase 5)

1. **A store-side CAS narrows, but does not eliminate, the demotion race —
   and cannot.** The claim makes check-and-act one atomic statement, so a
   demotion persisted before it always wins. But a demotion can still
   commit while the transport call is in flight; strict exclusion would
   mean holding a DB row lock across a network write (and SQLite cannot
   even express `SELECT ... FOR UPDATE`). The HANDOFF's "a store-side lock
   would close it fully" was too optimistic. What actually guarantees
   correctness is claim + converge: every demotion schedules cohort
   refreshes after its commit, so the at-most-one broadcast that slips
   into the transport window is immediately superseded.
2. **Iteration identity is knowable at enter time only because relations
   load before the first yield.** `items.each` materializes the whole
   result (recorded on the loop node) before the first iteration renders —
   that ordering is what lets the open tag stamp the instance address.
   `find_each`/batching would break it (batch N's ids arrive late);
   unsoundness detection would catch the mismatch and fail closed, but a
   real gem should verify batched iteration explicitly.
3. **The unsound-marker trick preserves cross-viewer evidence.** Soundness
   is a structural property of the render, so both viewers produce the
   identical `__unsound__` marker — divergence is never manufactured. An
   asymmetric case (sound for one viewer, unsound for the other) would
   localize as an island; not observed in any fixture.
4. **`find_by` predicates were silently unrecorded before the
   statement-cache door.** The pre-existing suites never noticed because
   every fixture page also held a broader relation read that masked it.
   The audit is what exposed the gap class; the nil-result case
   (`find_by` returning nothing records NOTHING via instantiation) was
   fully invisible until now.
5. **RefreshSync's own store reads must not become page dependencies.**
   Once statement-cache and pluck doors existed, cohort-table lookups on
   GET-boundary writes started recording `refresh_sync_cohorts` into page
   read sets — a feedback loop. Own tables are now excluded from read-set
   recording (distinct from the user-facing ignore list, whose tables ARE
   recorded so the misuse warning can fire).
6. **One phase-4 assertion was abolished by design**: pulse_fixture's
   "first delivery baselines every region exactly once" asserts the exact
   behavior item 3 removes. Its assertions were updated (only that test);
   everything else passed unmodified.
