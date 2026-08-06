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
