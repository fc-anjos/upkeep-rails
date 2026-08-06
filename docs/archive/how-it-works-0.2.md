# How Upkeep Works

This document explains the runtime model behind Upkeep Rails. It intentionally
does not cover installation or common configuration; use the
[README](../README.md) for that public API surface.

## The Runtime Loop

Upkeep connects reads to later writes without asking the write path to name a
view or Turbo Stream target:

1. A successful HTML GET runs normally through Rails while Upkeep records the
   rendered frame graph, Active Record dependencies, and the request and
   identity inputs the response actually reads.
2. Active Record relations are converted to their generated SQL. Upkeep parses
   that SQL in the database adapter's dialect, qualifies it against the Rails
   schema, and derives the physical tables, columns, predicates, and query
   shape that can make the result stale.
3. Upkeep stores the replayable graph and injects a hidden subscription source
   into the response. The browser connects over Action Cable; only after the
   activation token and subscriber identity are accepted does the subscription
   become visible to write lookup.
4. Controller requests and Active Job executions collect Active Record change
   facts from `after_commit` and supported callback-skipping write APIs. Upkeep
   matches their tables, records, and changed columns against the active
   subscription index.
5. The planner chooses the narrowest proven target, replays the required Rails
   render work with the captured inputs, coalesces equivalent output, and
   broadcasts Turbo Stream HTML. Turbo performs the DOM update.

## Rendered Pages

A rendered page is a successful HTML GET that Upkeep can keep fresh. The
request runs normally through Rails. Upkeep observes the controller, Action View
rendering, Active Record records, relations and calculations, request inputs,
and identity inputs used by the response.

Upkeep only captures successful HTML responses. Non-HTML responses, redirects,
failed responses, and explicit non-page interactions continue to behave like
ordinary Rails responses.

By default, every eligible GET is reactive. With opt-in request activation,
only controller actions declared with `upkeep_reactive` start new
subscriptions. A Turbo Frame request carrying an existing Upkeep subscription
continues that subscription even in opt-in mode so frame navigation does not
silently drop the rest of the page graph.

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

### Controller Work and Render Regions

Dependencies inherit the frame that is active when the read occurs. A query
inside a partial or `upkeep_frame` belongs to that render region. A query in a
controller callback or action runs before rendering, so its narrowest sound
boundary is the page:

```ruby
before_action do
  @show_reminder = current_user.time_logs.where(log_date: Date.current).count.zero?
end
```

Rails does not record which later template expression consumes an instance
variable. Ruby may also pass or access that value dynamically, so Upkeep cannot
reliably infer that `@show_reminder` affects only one element. A matching
`TimeLog` change can therefore select a page replay.

When controller work exists only to render one section, execute it inside that
section instead:

```erb
<%= upkeep_frame "layout/time-log-reminder" do %>
  <div data-upkeep-render-site="layout/time-log-reminder">
    <% if time_log_reminder_data %>
      <%= render "shared/time_log_reminder" %>
    <% end %>
  </div>
<% end %>
```

The helper or partial can perform the query while this frame is active. Upkeep
then associates the dependency with the reminder region instead of the page.
The region must always render a stable target, including when its conditional
content is empty, so it can transition in either direction.

This is a granularity rule, not a refusal: controller-level reads remain live
through a conservative page replay. Use an explicit region only when that
broader replay is undesirable and the application knows the true presentation
boundary.

## Surfaces

A surface is the set of facts about future writes that would make a frame
stale.

For Active Record, Upkeep derives surfaces from observed record attributes,
materialized relations, calculations, and rendered collections. Since 0.2, the
production query-analysis boundary is generated SQL, not Arel. Upkeep parses
`relation.to_sql` with SQLGlot in the adapter's dialect, qualifies tables and
columns against the Rails schema cache, and lowers the result into physical
sources, referenced columns, simple predicates, equality edges, and query
shape.

A rendered collection of open cards ordered by position therefore produces a
surface tied to the cards table, the columns that decide membership and order,
and the records rendered in that collection. The same analysis works when the
generated SQL contains ordinary raw predicates, raw joins, aliases, derived
tables, subqueries, CTEs, or set operations, as long as SQLGlot can resolve all
physical sources and columns.

Normal creates, updates, and destroys produce facts from `after_commit`.
Supported callback-skipping operations such as `touch`, `update_columns`,
`update_all`, and `delete_all` have explicit observers. At the end of the
controller or job boundary, Upkeep compares the collected facts with registered
surfaces. Only frames whose surfaces can be affected are selected for delivery.

Controller requests and Active Job executions both establish a change-capture
boundary. After the boundary completes, Upkeep plans and delivers updates for
the committed Active Record changes. Sidekiq jobs using the Active Job adapter
are covered by this lifecycle; direct Sidekiq workers are not.

## Identity Boundaries

An identity boundary is state that decides who may receive a live update.

Upkeep records observed CurrentAttributes, Warden, session, cookie, and request
reads for replay and sharing. It does not infer subscriber identity by naming
convention. The app declares which render-time value maps to which
subscribe-time ActionCable value.

Only values observed by the response are snapshotted into a replay recipe.
Controller replays rebuild the request from Rails' current application request
configuration plus those observed params, headers, session values, cookies,
and Warden users. Unread session and cookie state is neither copied into the
recipe nor allowed to change its sharing signature.

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

Registration and activation are separate. The response creates a pending
subscription and gives the browser a short-lived activation token. The Action
Cable channel validates that token and derives the subscriber identity before
activating reverse-index entries or attaching delivery streams. A failed token
or identity check rejects the connection instead of exposing a subscription to
delivery.

Turbo Frames are graph scopes inside that page subscription. A frame response
replaces the matching scope while the shell and sibling scopes remain intact.
The browser connects the composed subscription before disconnecting the
previous one, so a frame visit never leaves the visible page without its full
dependency graph.

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

When a change was committed while handling a GET or HEAD request, the refresh
tag also carries that request's Turbo id as `request-id` (from
`Turbo.current_request_id` or the `X-Turbo-Request-Id` header). Turbo 8's client
ignores refreshes for its own recent requests, so view tracking cannot refresh
the viewer who caused it into a self-refresh loop. Mutations omit the request id
so the originating tab still refreshes when its response does not render every
affected region. Writes from jobs or the console also refresh everyone.

For rendered operations, Upkeep groups targets with the same operation,
target, identity, sharing boundary, deployment shape, and replay recipe. It
renders one representative per group, then merges byte-identical streams.
Public render sites may use a shared Action Cable stream; subscriber-specific
work stays on per-subscription streams. This makes render work follow distinct
view shapes while preserving identity boundaries.

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
- materialized Active Record relations, including empty results
- Active Record relation collection renders and their materialized provenance
- `pluck` projections and Active Record calculations such as `count`, `sum`,
  `average`, `minimum`, and `maximum`
- generated SELECT SQL parsed and qualified through SQLGlot
- record creates, updates, and destroys observed through `after_commit`
- supported callback-skipping writes such as `touch` and `update_columns`
- supported bulk `update_all` and `delete_all` writes
- physical table, column, predicate, equality, and query-shape coverage derived
  from the generated SQL

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
| Active Record relations whose generated SQL cannot be parsed and resolved: unsupported adapter-specific syntax, an unknown physical source, or a column that cannot be qualified against the application schema. | The SQL analysis cannot prove complete table and column coverage. Raw SQL fragments are not inherently opaque in 0.2; failure is based on the generated statement and schema proof. | Upkeep refuses live registration for the response instead of subscribing to an incomplete dependency set. |
| Database reads that bypass observed Active Record relation and attribute paths, such as direct connection SQL or stored procedure results. | No read dependency is attached to the render graph. | The read does not make the page live. Another captured dependency may still cause a replay that reads the new value. |
| Controller queries that are never rendered as a collection boundary. | There is no DOM collection surface where membership can be appended, removed, prepended, or replaced. | The page can still render normally. Scalar relation output may be tracked as a page-level dependency, but it does not unlock collection stream planning. |
| Reads from external stores or process state: Redis, HTTP APIs, files, global variables, class variables, singleton caches, background thread state, or service memoization. | Active Record commit facts cannot select these reads, and Upkeep has no source adapter for their lifecycle. | They are not live dependencies. If another observed dependency causes a replay, normal Rails code may read the new value during that replay. |
| Writes outside observed Active Record paths: direct connection SQL, writes in another datastore, or side effects that do not emit Upkeep change facts. | Upkeep cannot match a future change to an existing surface without a write fact. | No refresh is scheduled from that write. |
| Replay inputs that cannot be rebuilt: arbitrary objects, procs, IO handles, open clients, or values that only exist in one Ruby process. | A captured target must be replayable later, often in a different request context. | Non-replayable values block the narrow replay path until represented as stable data. |
| Patch targets Upkeep cannot identify in rendered HTML. | Delivery needs a stable page, render-site, fragment, or member target. | Upkeep uses the narrowest proven target. If no safe target exists, the boundary is refused. |

## Query Shapes

Upkeep 0.2 analyzes the SQL Active Record will send to the database. Production
code does not inspect `Relation#arel` or dispatch on Arel node types. SQLGlot
parses the generated statement using the PostgreSQL, MySQL, SQLite, SQL Server,
or Oracle dialect selected from the Active Record adapter, and Upkeep resolves
the parsed sources against the application's schema.

This means ordinary SQL fragments are supported inputs:

```ruby
Story.where("score >= 0").order("created_at DESC")
User.joins("INNER JOIN posts ON posts.user_id = users.id")
Story.from("(SELECT * FROM stories WHERE archived = FALSE) stories")
```

Aliases, subqueries, correlated subqueries, CTEs, and set operations are lowered
to their physical tables. Simple equal, not-equal, `IN`, and null predicates
retain literal values so Upkeep can rule out unrelated writes. Other
expressions still contribute their referenced tables and columns even when
they cannot provide value-level filtering.

The analysis fails closed. A query dependency is accepted only when every
physical source and referenced column has proven coverage. If parsing,
qualification, or source validation fails, Upkeep refuses the response rather
than falling back to the relation's primary table. Write-side analysis has a
separate conservative table-level fallback so an unsupported bulk-write
predicate cannot suppress invalidation.

Controller materialization is supported when the rendered value keeps a
relation proof:

```ruby
def index
  @cards = Card.where(status: "open").order(:position).to_a
end
```

```erb
<%= render partial: "cards/card", collection: @cards, as: :card %>
```

Upkeep analyzes the relation before it executes and associates the resulting
provenance with the materialized records. When Action View later renders that
same collection, Upkeep attaches the collection dependency to the render-site
boundary. A materialized relation that is never rendered as a collection is
not a collection lifecycle dependency by itself.

Scalar relation output is tracked as a page-level query dependency. This
includes `pluck` and calculations such as `count`, `sum`, `average`, `minimum`,
and `maximum`:

```ruby
@tag_names = Tag.where(active: true).pluck(:name)
@open_count = Card.where(status: "open").count
```

These scalar dependencies can select a page replay when referenced columns or
membership predicates change. They are not collection dependencies, so they do
not participate in append/remove/prepend planning.

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
