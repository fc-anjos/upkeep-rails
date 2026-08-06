# upkeep-rails

Automatic live-updating pages for Rails. Upkeep records what each rendered
page actually read — at execution time, from Active Record itself — and when
matching data changes, tells every browser looking at an affected page to
update. No broadcast declarations, no view annotations, no custom JavaScript.

```erb
<%# your views, untouched %>
```
```ruby
# your models, untouched
```

Install the gem, run the generator, and pages update themselves.

## The honest comparison: `broadcasts_refreshes`

turbo-rails already ships one-line reactivity:

```ruby
class Card < ApplicationRecord
  broadcasts_refreshes_to :board
end
```

Upkeep is a machine that writes those declarations for you — correctly, at
runtime, from evidence. What the hand-written version can't do:

- **Coverage drift.** A page that renders cards, their board, the assignees,
  and a counter depends on four tables. `broadcasts_refreshes` covers the
  ones somebody remembered to declare, and silently stops matching when a
  view gains a new dependency. Upkeep's read set IS the dependency list,
  re-derived on every render.
- **`update_all` / `delete_all` / `insert_all`.** Callback-based broadcasting
  never fires for bulk writes. Upkeep observes them at the statement level,
  defers to the transaction's outcome, and — where the database supports
  `RETURNING` (probed at boot, never assumed from the adapter's name) — knows
  exactly which rows changed.
- **Precision.** `broadcasts_refreshes` refreshes every subscriber of a
  stream. Upkeep matches each write against each page's recorded ids and
  predicates: a write to board 2 does not refresh viewers of board 1.
- **Herd economics.** For pages proven identical across viewers, upkeep can
  render ONCE and broadcast the result instead of letting N browsers
  re-request the page (measured 100–200x cheaper at 10–500 viewers).

## How it works

**Tier P (the default, and the sole correctness mechanism): debounced Turbo 8
refresh.** Every captured GET registers a *cohort* — the page's read set
(loaded ids, simple where-predicates, per-table fallbacks) keyed to a private
stream. A committed write that matches schedules one debounced
`turbo_stream.refresh`; the browser re-fetches with its own credentials.
Every delivered byte is rendered *as the viewer*, so this path cannot leak,
and everything else in the gem is allowed to fail toward it.

**Tier S (earned, never configured): render-once shared broadcast.** Surfaces
— top-level partials, detected automatically — are promoted only by runtime
evidence: multiple authenticated, role-diverse viewers whose rendered bytes
are identical, matched by a *scrubbed render* (fresh thread, bare controller,
empty session, cleared CurrentAttributes — anonymous by construction). A
promoted surface delivers one scrubbed render per write window instead of a
refresh per viewer. Any divergence instantly demotes the surface — or ejects
just the diverged member:

- A write to rows only one member's render read (their user row, their role
  row) ejects THAT member to personal refresh; everyone else keeps shared
  delivery. Their next matching render re-admits them.
- Column evidence sharpens the call for rows both renders read (your name is
  public, your admin flag is not).
- Entitlements no database row can witness (time-of-day branching, Ruby
  constants) emit no write signal by definition; the post-broadcast digest
  backstop catches them one render later. That bound is documented and final
  — it is the price of not constraining what your app is allowed to do.

There is no Tier S configuration. The evidence bar is the gate. The only
switch is `UPKEEP_DISABLE_REGION_BROADCAST=1` — an emergency ops escape
hatch that forces refresh-only delivery, for the day the demotion machinery
itself misbehaves. If you are setting it for any other reason, file a bug.

**Principles.** Identity fails closed; freshness fails open. Whenever upkeep
silently does less than you'd expect, it warns (`*.upkeep`
notifications: capture refused, degrade to table-level, region
unbroadcastable, payload over the transport cap, ignored-table misuse, cable
topology that cannot deliver). The origin tab is just another subscriber.
Zero JavaScript beyond stock turbo-rails.

## Install

```ruby
# Gemfile
gem "upkeep-rails"
```

```sh
bin/rails generate upkeep:install
bin/rails db:migrate
```

The generator creates four bookkeeping tables, an initializer, and a
`.herb.yml` (provenance: views compile through ReActionView/Herb so shared
content can be addressed and broadcast per-region). Opt controllers in with
`upkeep` (an `around_action`); everything else — read tracking, write
observation, cable subscription tags, reconnect resync, lifecycle sweeping —
is automatic.

Cable: upkeep uses whatever Action Cable adapter your app uses and never
touches its config. At boot it checks the topology and warns loudly when the
async adapter meets a multi-process server (deliveries cannot cross
processes) — `solid_cable`, `redis`, or `postgresql` all work.

## What the warnings mean

Silent degradation is a bug class; loud degradation is a feature. The ones
you may meet: `capture_refused` (an unattributable query ran during capture —
no cohort, no liveness, tell us), `capture_incomplete` (a read degraded to
table-level: more refreshes, never staleness), `row_identity_unavailable`
(your database can't answer RETURNING; bulk writes match table-level),
`region_unbroadcastable` (byte-shared content with no stamped element rides
refresh), `payload_limit_degrade` (one oversized Tier S delivery stepped
aside), `cable_topology` (see above).

## Development

`bash run_all.sh` runs every suite against a throwaway SQLite database.
The cross-process suite wants a local redis; the browser smoke test wants
Chrome + chromedriver and skips (with the reason) without them. CI runs the
Rails 8.1 and 7.1 matrix — the 7.1 leg is the version-coupling ledger:
internal seams this gem rides are re-verified there on every push.
