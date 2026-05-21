# Upkeep Rails

Upkeep Rails refreshes ordinary Rails pages when the data, request inputs, or
identity values they used change.

A successful HTML GET captures what the page rendered. A later Active Record
commit emits facts about what changed. Upkeep matches those facts to affected
rendered frames and delivers Turbo Stream updates over ActionCable.

The design goal is Rails-shaped DX: controllers load state, views render ERB,
models commit writes, and Upkeep derives the reactive boundary from the Rails
surfaces it observes. There is no query catalog, no `watch` or `track` DSL, and
no host-maintained list of identity dimensions.

## Why Upkeep

In ordinary Rails and Turbo code, the write can stay in the controller and the
stream response can live in a template. The flow still has to name every stream
target, counter, partial, or page region that might now be stale:

```ruby
# app/controllers/cards_controller.rb
class CardsController < ApplicationController
  def update
    @card = Card.find(params[:id])
    @card.update!(card_params)

    @board = @card.board
    @open_card_count = @board.cards.open.count

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to @board }
    end
  end
end
```

```erb
<%# app/views/cards/update.turbo_stream.erb %>
<%= turbo_stream.replace dom_id(@card),
  partial: "cards/card",
  locals: { card: @card } %>

<%= turbo_stream.update "open_card_count", @open_card_count %>
```

That works, but the update flow is coupled to the UI it happens to refresh.
Adding another dependent page, sidebar, filter, or counter means revisiting old
stream templates, controller assignments, callbacks, or broadcasts.

With Upkeep, the controller performs the domain action and stops:

```ruby
class CardsController < ApplicationController
  def update
    Card.find(params[:id]).update!(card_params)
    head :ok
  end
end
```

The GET that rendered the page already recorded which templates, collections,
records, request values, and identity values the response used. When the commit
lands, Upkeep selects the affected frames, rerenders the narrowest proven
target, and leaves unrelated subscribers alone.

## Status

Upkeep Rails is early alpha. Application code should start from the documented
public entry points:

- `gem "upkeep-rails"` - load the Railtie.
- `bin/rails generate upkeep:install` - install storage, cable, and browser
  bootstrap files.
- `config.upkeep.enabled` - enable or disable runtime capture.
- `config.upkeep.subscription_store` - choose `:active_record` or explicit
  development/test `:memory` storage.
- `config.upkeep.refused_boundary_behavior` - raise or warn when a reactive
  boundary cannot be proven.
- `Upkeep::Rails::Cable::Channel` - the generated browser client subscribes to
  this channel.
- `Upkeep::Rails::Testing` - integration test helpers.

Everything under `Upkeep::Runtime`, `Upkeep::Dependencies`,
`Upkeep::Invalidation`, `Upkeep::Subscriptions`, `Upkeep::Delivery`,
`Upkeep::DAG`, probes, proofs, and benchmark harness code is internal.

## Core Concepts

### Rendered Page

A **rendered page** is a successful HTML GET that Upkeep can keep fresh. The
request runs normally through Rails. Upkeep observes the controller, Action View
rendering, Active Record reads, request inputs, and identity inputs used by the
response.

A rendered page describes *what the browser saw*.

### Frame

A **frame** is a rendered page, template, partial, collection render site, or
fragment with a stable delivery target. Frames let Upkeep refresh a specific
part of the page instead of replaying the whole response when a narrower update
is proven safe.

A frame describes *where a refresh can land*.

### Surface

A **surface** is the set of facts about future writes that would make a frame
stale. For Active Record, Upkeep derives surfaces from observed record
attributes, rendered collections, and relation shape where Rails exposes a
structural Arel query.

For example, a rendered collection of open cards ordered by position produces a
surface tied to the cards table, the columns that decide membership, and the
records rendered in that collection. A card update only selects the frames whose
surface it can affect.

A surface describes *when to rerender*.

### Identity Boundary

An **identity boundary** is observed viewer-specific state: `CurrentAttributes`,
Warden or Devise users, session values, cookies, request values, and ActionCable
connection identifiers. Upkeep uses these observed values to decide whether
work can be shared or must stay partitioned by viewer.

An identity boundary describes *who may share a result*.

### Subscription

A **subscription** is the browser's live connection back to the captured page.
Upkeep injects a marker into successful HTML responses. The generated browser
bootstrap reads that marker, subscribes over ActionCable, and applies received
Turbo Stream payloads.

A subscription describes *where updates should be sent*.

### Proven Delivery

**Proven delivery** means Upkeep only emits the narrowest update it can justify.
It may `append`, `prepend`, `remove`, `replace`, or replay an enclosing render
site depending on the proof available. If Upkeep cannot prove a boundary, it
refuses registration instead of silently widening into unsafe broad
invalidation.

Proven delivery describes *how much to refresh safely*.

### Glossary

| Term | What it means |
| --- | --- |
| Capture | The GET-time observation of render structure, data reads, request inputs, and identity inputs. |
| Commit facts | Active Record lifecycle facts such as table, model, id, changed attributes, and old/new values. |
| Replay | Rerendering a captured page, render site, or fragment with the observed inputs needed for that target. |
| Shared render | One replay reused for multiple anonymous or public subscribers with the same safe delivery shape. |
| Opaque | Visible to application code, but not structurally inspectable enough for Upkeep to prove dependencies, replay inputs, or delivery targets. Raw SQL strings, process-local objects, and ambiguous HTML roots are common examples. |
| Refused boundary | A page Upkeep did not register because a query, identity input, replay input, or DOM target could not be proven. |

## Quick Start

### 1. Add Upkeep

Add the gem to a Rails app:

```ruby
gem "upkeep-rails"
```

The Railtie installs hooks when Rails loads Active Record, Action Controller,
and Action View. The runtime is enabled by default.

### 2. Run The Installer

```sh
bin/rails generate upkeep:install
bin/rails db:migrate
```

The generator creates subscription tables, writes `config/initializers/upkeep.rb`,
mounts ActionCable when needed, pins Turbo and ActionCable for importmap apps,
and imports the browser bootstrap from `app/javascript/application.js`.

### 3. Configure Subscription Storage

Production uses the ActiveRecord subscription store by default and fails fast
when the Upkeep subscription tables are missing:

```ruby
Rails.application.configure do
  config.upkeep.enabled = true
  config.upkeep.subscription_store = :active_record
end
```

For development or isolated tests that do not run the installer migration, opt
into the in-process store explicitly:

```ruby
config.upkeep.subscription_store = :memory
```

For more than one Puma worker, configure ActionCable with a shared adapter such
as Redis or Solid Cable. The subscription store decides which subscribers need
work; ActionCable decides which worker owns each WebSocket connection.

### 4. Render Normal Rails Views

Controllers keep loading Active Record models and relations:

```ruby
class BoardsController < ApplicationController
  def show
    @board = Board.find(params[:id])
    @cards = @board.cards.order(:position)
  end
end
```

Templates keep rendering ERB and partial collections:

```erb
<main>
  <h1><%= @board.name %></h1>

  <ul id="cards">
    <%= render partial: "cards/card", collection: @cards, as: :card %>
  </ul>
</main>
```

Successful HTML GET responses are captured automatically. Upkeep records the
rendered page, render sites, fragments, collection surfaces, identity inputs,
and request inputs, then injects the subscription marker into the response.

### 5. Keep Write Paths Focused

Writes keep doing domain work:

```ruby
class CardsController < ApplicationController
  def update
    Card.find(params[:id]).update!(card_params)
    head :ok
  end
end
```

After the commit, Upkeep dispatches invalidation facts, selects matching
subscriptions, rerenders the narrowest proven target, and sends Turbo Stream
payloads to the connected browsers.

## How Refresh Works

1. A successful HTML GET captures a rendered page.
2. The browser subscribes using the injected `data-upkeep-subscription` marker.
3. Active Record commits emit lifecycle facts.
4. Upkeep matches those facts against active surfaces.
5. Matching frames replay or use a proven stream operation.
6. Equivalent public targets render once and fan out to matching subscribers.
7. Identity-bound targets remain partitioned by observed identity boundaries.

## What Upkeep Observes

Render structure:

- Rails-resolved page templates.
- Partial and object partial renders.
- Collection render sites and their child fragments.
- Single-root fragment and render-site DOM targets.

Data dependencies:

- Active Record attribute reads.
- Active Record relation collection renders.
- Active Record callback writes and bulk `update_all` / `delete_all` writes.
- Relation table/column coverage derived from Arel where Rails exposes a
  structural query shape.

Identity and ambient inputs:

- `ActiveSupport::CurrentAttributes` reads.
- Warden and Devise user reads through Warden.
- Session and cookie reads.
- Request values such as host, path, params, user agent, and remote IP.
- ActionCable connection identifiers.

## What Upkeep Cannot Capture

Upkeep captures reactive facts, not arbitrary Ruby execution. A boundary is
capturable only when Upkeep can prove the future write facts that affect it, the
target that can be replayed or patched, and the identity inputs that decide
whether it can be shared.

`Opaque` means Upkeep can see that application code used something, but Rails
did not expose enough structure for Upkeep to decide what future change should
refresh it or how to replay it safely.

This is a safety rule, not a parser preference. A live boundary must answer
three questions:

1. Which future write facts can make this rendered result stale?
2. Which target can Upkeep replay or patch when that happens?
3. Which observed identity inputs decide whether the result can be shared?

If any answer is missing, Upkeep would have to choose between missing updates,
refreshing too broadly, or sharing viewer-specific output with the wrong
subscriber. It refuses that boundary instead.

| Surface | Why it is not capturable | Developer experience |
| --- | --- | --- |
| Opaque Active Record relations: raw SQL predicates, raw joins, raw `from` sources, unknown table aliases, opaque order expressions, or opaque pluck columns. | Rails no longer exposes enough structure to prove table, column, predicate, and lifecycle coverage. | Development/test raises `Upkeep::ActiveRecordQuery::OpaqueRelationError` before registering. Warn mode logs, emits `refused_boundary.upkeep`, and refuses the live boundary instead of widening to an unsafe dependency. Rewrite with structural Active Record or Arel when the boundary should be live. |
| Controller queries that are never rendered as a collection boundary. | There is no DOM collection surface where membership can be appended, removed, prepended, or replaced. | The page can still render normally. Scalar relation output can be tracked as a page-level dependency, but it does not unlock collection stream planning. Render the relation through a collection partial when collection lifecycle matters. |
| Reads from external stores or process state: Redis, HTTP APIs, files, global variables, class variables, singleton caches, background thread state, or service memoization. | Active Record commit facts cannot select these reads, and Upkeep has no source adapter for their lifecycle. | They are not live dependencies today. If another observed dependency causes a replay, normal Rails code may read the new value during that replay; the external read itself will not trigger one. Use existing app mechanisms, explicit broadcasts, or future source adapters for those domains. |
| Writes outside observed Active Record paths: direct connection SQL, writes in another datastore, or side effects that do not emit Upkeep change facts. | Upkeep cannot match a future change to an existing surface without a write fact. | No refresh is scheduled from that write. Prefer Active Record write APIs for capturable models, or keep a manual invalidation/broadcast path for sources Upkeep does not observe yet. |
| Replay inputs that cannot be rebuilt: arbitrary objects, procs, IO handles, open clients, or values that only exist in one Ruby process. | A captured target must be replayable later, often in a different request context. | Keep frame locals and render options to records, relations, arrays, hashes, literals, and observed request/session/cookie values. Non-replayable values block the narrow replay path until they are represented as stable data. |
| Patch targets Upkeep cannot identify in rendered HTML. | Delivery needs a stable page, render-site, fragment, or member target. Ambiguous or missing roots cannot be patched safely. | Upkeep uses the narrowest proven target. If a narrow target is not proven but an enclosing target is, delivery deoptimizes to the enclosing target; if no safe target exists, the boundary is refused or tests expose the missing target. |

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

## Identity And Sharing

Upkeep observes identity only when application code reads identity-shaped state.
If a page reads `Current.user`, session values, cookies, request values, or
connection identifiers, delivery is partitioned by those observed values.

If a page never reads identity state, it can stay anonymous-public. Anonymous
subscribers with the same subscription shape can share compiled subscription
structure and update renders. Upkeep does not share initial response HTML.

Session, cookie, and request replay stores only observed values needed to rerun
the page. Unread session keys, cookies, and request headers are not copied into
the replay payload.

## Refused Boundaries

Upkeep distinguishes a refused boundary from a deoptimization.

A **refused boundary** means Upkeep cannot prove correctness. In
development/test, refused boundaries raise by default. In production, they warn,
emit `refused_boundary.upkeep`, and skip live registration for that boundary by
default:

```ruby
config.upkeep.refused_boundary_behavior = :raise # or :warn
```

This is intentional. A page that cannot be proven should behave like ordinary
Rails HTML instead of registering a broad or unsafe live dependency.

A **deoptimization** means Upkeep can still prove correctness, but not the
cheapest operation. The page remains live, and delivery falls back to a broader
proven target such as a render site or page replay. Planning and delivery
telemetry record the deoptimization reason so benchmarks can separate safety
fallbacks from true refusal.

## Testing

Use `Upkeep::Rails::Testing` for app-level assertions around subscription
registration and delivery.

Run the project test suite with the project Ruby:

```sh
mise exec -- ruby -S rake test
mise exec -- ruby bin/test
```

`bin/test` runs the gem tests, both maintained benchmark app test suites, and
the proof runner. The proof runner writes JSON reports to `results/`.

