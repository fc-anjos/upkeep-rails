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
