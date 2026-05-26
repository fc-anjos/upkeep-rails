# How Upkeep Works

This document explains the runtime model behind Upkeep Rails. It intentionally
does not cover installation or common configuration; use the
[README](../README.md) for that public API surface.

## Rendered Pages

A rendered page is a successful HTML GET that Upkeep can keep fresh. The
request runs normally through Rails. Upkeep observes the controller, Action View
rendering, Active Record reads, request inputs, and identity inputs used by the
response.

Upkeep only captures successful HTML responses. Non-HTML responses, redirects,
failed responses, and explicit non-page interactions continue to behave like
ordinary Rails responses.

## Frames

A frame is a rendered page, template, partial, collection render site, or
fragment with a stable delivery target.

Frames let Upkeep refresh a specific part of the page instead of replaying the
whole response when a narrower update is proven safe. A page frame is the broad
fallback. A render-site or fragment frame is narrower.

Upkeep instruments Action View templates and adds internal `data-upkeep-*`
markers for page roots, fragment roots, and safe collection render-site
containers. Normal templates do not need to call helper APIs directly.

The `upkeep_frame` helper is an advanced escape hatch for generated or
helper-built boundaries that cannot be derived from template source. Ordinary
ERB and partial collections should not need it.

## Surfaces

A surface is the set of facts about future writes that would make a frame
stale.

For Active Record, Upkeep derives surfaces from observed record attributes,
rendered collections, and relation shape where Rails exposes structural Arel
queries. A rendered collection of open cards ordered by position produces a
surface tied to the cards table, the columns that decide membership and order,
and the records rendered in that collection.

When a write commits, Upkeep compares the write facts with registered surfaces.
Only frames whose surfaces can be affected are selected for delivery.

## Identity Boundaries

An identity boundary is state that decides who may receive a live update.

Upkeep records observed CurrentAttributes, Warden, session, cookie, and request
reads for replay and sharing. It does not infer subscriber identity by naming
convention. The app declares which render-time value maps to which
subscribe-time ActionCable value.

The safety rule is simple: if rendered output depends on a non-public identity,
only subscribers proving the same identity may receive that output. If Upkeep
cannot identify the boundary, it refuses live registration rather than sending
viewer-specific HTML to the wrong browser.

Absent identities are public. For example, if a logged-out page reads a nil
viewer, that nil value can be treated as anonymous-public instead of
subscriber-specific.

## Subscriptions

A subscription is the browser's live connection back to the captured page.

Upkeep injects a body-scoped `<upkeep-subscription-source>` marker into
successful HTML responses. The generated browser bootstrap upgrades that marker
into a Turbo stream source, subscribes over ActionCable, and lets Turbo process
received stream payloads.

The server stores a replayable subscription graph for the rendered page. The
graph contains frames, dependencies, target metadata, replay recipes, request
inputs, and identity information needed to plan later updates.

## Proven Delivery

Proven delivery means Upkeep only emits the narrowest Turbo operation it can
justify.

Depending on the proof available, delivery may use:

- `append`
- `prepend`
- `remove`
- `replace`
- `update`
- Turbo page `refresh`

Render-site replays use Turbo Stream `update method="morph"` against the real
HTML element Upkeep marked as the render site. The stream template is the
render site's children, so `update` preserves the legal container element and
swaps its contents.

Page-level fallbacks use Turbo Stream `refresh method="morph"
scroll="preserve"` instead of replacing `<html>` or writing a new document from
JavaScript.

## Deoptimization

A deoptimization means Upkeep can still prove correctness, but not the cheapest
operation.

For example, a collection member update might not have enough proof for a
single member `replace`, but the enclosing render site might still be safe to
rerender. In that case, the page remains live and Upkeep falls back to the
broader proven target.

Planning and delivery telemetry record deoptimization reasons so benchmarks and
tests can separate safety fallbacks from true refusals.

## Refused Boundaries

A refused boundary means Upkeep cannot prove correctness.

If Upkeep cannot answer which future write facts can make a rendered result
stale, which target can be replayed or patched, or which identity inputs decide
sharing, it refuses the live boundary.

This is intentional. A boundary that cannot be proven should behave like
ordinary Rails HTML instead of registering a broad or unsafe live dependency.

Refusal is different from deoptimization:

- refusal: Upkeep cannot prove correctness, so the boundary is not live
- deoptimization: Upkeep can prove correctness through a broader target, so the
  boundary remains live

## What Upkeep Observes

Render structure:

- Rails-resolved page templates
- partial and object partial renders
- Action View-instrumented collection render sites and child fragments
- polymorphic `render @records` collection shorthand when runtime rendering
  confirms a collection
- `tag.*` and `content_tag` containers lowered by Herb into ordinary template
  structure
- single-root fragment targets and legal render-site container targets

Template parsing:

- Upkeep plans narrow source-derived targets only from templates that pass
  Herb's strict parser.
- If strict parsing fails but Herb can recover with `strict: false`, Upkeep
  reports the strict parser diagnostics as warnings and may still add broad
  page or fragment root markers.
- Recovered render sites are diagnostic only. Fix strict warnings before
  expecting narrow collection updates from that template.

Data dependencies:

- Active Record attribute reads
- Active Record relation collection renders
- Active Record callback writes
- supported bulk `update_all` and `delete_all` writes
- relation table and column coverage derived from Arel where Rails exposes a
  structural query shape

Identity and ambient inputs:

- `ActiveSupport::CurrentAttributes` reads
- Warden and Devise user reads through Warden
- session and cookie reads
- request values such as host, path, params, user agent, and remote IP
- declared Upkeep identities that map observed render-time values to
  ActionCable subscribe-time values

## What Upkeep Cannot Capture

Upkeep captures reactive facts, not arbitrary Ruby execution. A boundary is
capturable only when Upkeep can prove the future write facts that affect it,
the target that can be replayed or patched, and the identity inputs that decide
whether it can be shared.

These surfaces are not capturable today:

| Surface | Why it is not capturable | Runtime behavior |
| --- | --- | --- |
| Opaque Active Record relations: raw SQL predicates, raw joins, raw `from` sources, unknown table aliases, opaque order expressions, or opaque pluck columns. | Rails no longer exposes enough structure to prove table, column, predicate, and lifecycle coverage. | Upkeep refuses the live boundary instead of widening to an unsafe dependency. |
| Controller queries that are never rendered as a collection boundary. | There is no DOM collection surface where membership can be appended, removed, prepended, or replaced. | The page can still render normally. Scalar relation output may be tracked as a page-level dependency, but it does not unlock collection stream planning. |
| Reads from external stores or process state: Redis, HTTP APIs, files, global variables, class variables, singleton caches, background thread state, or service memoization. | Active Record commit facts cannot select these reads, and Upkeep has no source adapter for their lifecycle. | They are not live dependencies. If another observed dependency causes a replay, normal Rails code may read the new value during that replay. |
| Writes outside observed Active Record paths: direct connection SQL, writes in another datastore, or side effects that do not emit Upkeep change facts. | Upkeep cannot match a future change to an existing surface without a write fact. | No refresh is scheduled from that write. |
| Replay inputs that cannot be rebuilt: arbitrary objects, procs, IO handles, open clients, or values that only exist in one Ruby process. | A captured target must be replayable later, often in a different request context. | Non-replayable values block the narrow replay path until represented as stable data. |
| Patch targets Upkeep cannot identify in rendered HTML. | Delivery needs a stable page, render-site, fragment, or member target. | Upkeep uses the narrowest proven target. If no safe target exists, the boundary is refused. |

## Query Shapes

Collection dependencies are accepted only with proven column coverage. Opaque
predicates or table-only sources are refused instead of widening into broad
invalidation.

Controller materialization is supported when the rendered value keeps a
structural relation proof:

```ruby
def index
  @cards = Card.where(status: "open").order(:position).to_a
end
```

```erb
<%= render partial: "cards/card", collection: @cards, as: :card %>
```

Upkeep attaches the collection dependency to the rendered collection boundary,
not to every controller query. A materialized relation that is never rendered as
a collection is not a lifecycle dependency by itself.

Scalar relation output is tracked as a page-level query dependency:

```ruby
@tag_names = Tag.where(active: true).pluck(:name)
```

Simple plucked columns are live and can select a page replay when they change.
They are not collection dependencies, so they do not participate in
append/remove/prepend planning.

## Testing Model

Use `Upkeep::Rails::Testing` for app-level assertions around subscription
registration and delivery.

Structure tests around behavior, not store internals:

- Most request and system tests can run against the memory store. Memory has
  the same public lifecycle as ActiveRecord: registration is fetchable
  immediately, lookup visibility starts on activation, touch updates liveness,
  unregister and prune remove lookup entries, and delivery uses the same
  planner surface.
- Keep a smaller ActiveRecord-backed integration slice for production-only
  concerns: generated migration shape, schema validation, durable rows,
  reload and rehydration, async persistence, and cross-process lookup.
- Do not assert implementation details that are unique to one store unless the
  test is explicitly about that implementation. For app behavior, assert the
  marker, activation, streams, broadcasts, and rendered bytes.

Useful helpers:

- `assert_upkeep_subscription_registered`
- `upkeep_subscription`
- `upkeep_stream_names`
- `activate_upkeep_subscription!`
- `capture_upkeep_broadcasts`
- `drain_upkeep_delivery!`
- `capture_upkeep_change_facts`
- `upkeep_match_report`

Use `capture_upkeep_broadcasts` when an app test needs to assert rendered
Turbo Stream payloads without depending on the host app's Action Cable test
adapter. The helper captures Upkeep delivery after planning and rendering, but
before the transport broadcasts.

Use `capture_upkeep_change_facts` and `upkeep_match_report` when debugging an
invalidation miss. Capture the committed facts produced by the request, then
dry-run them against the current subscription store. The report returns the
candidate count, matched count, miss reason, and render targets without
broadcasting.

For structural subscription debugging, call `subscription.explain` or
`Upkeep::Rails.subscriptions.explain(subscription.id)`. Explanations summarize
the dependency tables and attributes, identity, frame count, lookup keys, and
metadata without requiring store-specific instance-variable inspection.
