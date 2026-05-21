# Upkeep Rails

Upkeep Rails refreshes ordinary Rails pages when the data, request inputs, or
identity values they used change.

A successful HTML GET captures what the page rendered. A later Active Record
commit emits facts about what changed. Upkeep matches those facts to affected
rendered frames and delivers Turbo Stream updates over ActionCable.

The design goal is Rails-shaped DX: controllers load state, views render ERB,
models commit writes, and Upkeep derives the reactive boundary from the Rails
surfaces it observes. There is no query catalog and no `watch` or `track` DSL.
For user-specific pages, apps declare only the bridge between an observed
render-time identity and the matching ActionCable connection identity.

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
- `Upkeep::Rails.configure` - configure runtime settings from initializers and
  declare identity bridges.
- `config.upkeep.enabled` - enable or disable runtime capture from Rails
  application or environment config.
- `config.upkeep.subscription_store` - choose `:active_record` or explicit
  development/test `:memory` storage.
- `config.upkeep.delivery_adapter` - choose `:active_job`, `:async`, or
  `:inline` for committed-change delivery.
- `config.upkeep.delivery_queue` - Active Job queue name for Upkeep delivery
  jobs.
- `config.upkeep.refused_boundary_behavior` - raise or warn when a reactive
  boundary cannot be proven.
- `config.upkeep.activation_token_expires_in` - signed marker token lifetime for
  activating the exact subscription rendered into the HTML response.
- `Upkeep::Rails.configure { |config| config.identify ... }` - declare each
  user, account, tenant, or session identity that must be matched again when
  the browser subscribes over ActionCable.
- `Upkeep::Rails::Cable::Channel` - the generated browser client subscribes to
  this channel.
- `Upkeep::Rails::Testing` - integration test helpers.

Use `Upkeep::Rails.configure` in `config/initializers/upkeep.rb`. Use
`config.upkeep.*` only from Rails application or environment config that runs
before initializers.

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

An **identity boundary** is state that decides who may receive a live update.
Upkeep records observed CurrentAttributes, Warden, session, cookie, and request
reads for replay and sharing, but it does not infer subscriber identity by
naming convention. Subscriber identity must be declared with
`config.identify`, then resolved again from ActionCable when the browser
subscribes.

An identity boundary describes *who may share a result*.

### Subscription

A **subscription** is the browser's live connection back to the captured page.
Upkeep injects a body-scoped `<upkeep-subscription-source>` marker into
successful HTML responses. The generated browser bootstrap upgrades that marker
into a Turbo stream source, subscribes over ActionCable, and lets Turbo process
received stream payloads.

A subscription describes *where updates should be sent*.

The marker includes a signed activation token for that subscription and is
`data-turbo-temporary`, so Turbo does not cache stale subscription handles. The
token lets the browser activate the exact rendered response it received on first
paint without requiring Upkeep to create a guest cookie or infer application
identity. Identified pages still use declared identity authorization in addition
to the activation token.

### Proven Delivery

**Proven delivery** means Upkeep only emits the narrowest Turbo operation it can
justify. It may `append`, `prepend`, `remove`, `replace`, `update`, or issue a
Turbo page `refresh` depending on the proof available. If Upkeep cannot prove a
boundary, it refuses registration instead of silently widening into unsafe broad
invalidation.

Render-site replays use Turbo Stream `update method="morph"` against the real
HTML element marked with `data-upkeep-render-site`. The stream template is the
render site's children, so `update` preserves the legal container element and
swaps its contents. Page-level fallbacks use Turbo Stream
`refresh method="morph" scroll="preserve"` instead of replacing `<html>` or
writing a new document from JavaScript.

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

The browser bootstrap is vendored into the host app at
`app/javascript/upkeep/subscription.js` so it works with importmap and bundler
apps without a package-manager dependency. After upgrading `upkeep-rails`, rerun
the installer or compare that file with the generated template. A stale browser
client can subscribe with an old payload shape and be rejected by the channel.

### 3. Configure Subscription Storage

The generated initializer keeps production on the durable ActiveRecord store
and uses the in-process memory store for ordinary test runs:

```ruby
# config/initializers/upkeep.rb
Upkeep::Rails.configure do |config|
  app_config = Rails.application.config.upkeep

  config.enabled = app_config.fetch(:enabled, true)
  config.subscription_store = app_config.fetch(:subscription_store, Rails.env.test? ? :memory : :active_record)
end
```

Use `config.upkeep.subscription_store = :active_record` in a test environment
or CI job when you want to exercise durable subscription rows, schema checks,
store reload, and cross-process lookup. Use the memory store for most
controller/system tests that only need the public subscription lifecycle.

```ruby
# config/environments/test.rb
config.upkeep.subscription_store = :active_record
```

For more than one Puma worker, configure ActionCable with a shared adapter such
as Redis or Solid Cable. The subscription store decides which subscribers need
work; ActionCable decides which worker owns each WebSocket connection.

The generated subscription source carries a stateless signed activation token.
The generated browser client forwards it to ActionCable, where Upkeep verifies
that the browser is activating the same subscription id that was rendered into
the response. The source lives in `<body>` and is marked `data-turbo-temporary`
so Turbo navigation and cache lifecycle disconnect stale subscriptions cleanly.
The default token lifetime is 24 hours and can be adjusted:

```ruby
Upkeep::Rails.configure do |config|
  config.activation_token_expires_in = 12.hours
end
```

### 4. Configure Identity For User-Specific Pages

Pages that depend on a user, account, tenant, or other authenticated actor need
an explicit identity bridge. The `current:`, `session:`, `cookie:`, or
`warden:` side tells Upkeep which render-time value is the identity. The
`subscribe` side tells Upkeep how to resolve the same identity from the
ActionCable connection:

```ruby
# config/initializers/upkeep.rb
Upkeep::Rails.configure do |config|
  config.identify :viewer, current: ["Current", :user] do
    subscribe { |connection| connection.current_user }
  end
end
```

The matching cable connection must expose that identity:

```ruby
# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = User.find_by(id: request.session[:user_id])
    end
  end
end
```

Session-backed identity can be declared directly:

```ruby
Upkeep::Rails.configure do |config|
  config.identify :viewer, session: :user_id do
    subscribe { |connection| connection.session[:user_id] }
  end
end
```

The `subscribe` block receives an Upkeep connection context. It delegates public
methods such as `current_user` to the ActionCable connection and exposes
`session` and `cookies` directly. The raw ActionCable `request` object is not
part of the public identity API.

By default, `nil` means a declared identity boundary is absent. That keeps
logged-out pages anonymous-public even when a layout checks `session[:user_id]`
or `Current.user`. If an app uses another sentinel for "not signed in", declare
it:

```ruby
Upkeep::Rails.configure do |config|
  config.identify :viewer, session: :user_id do
    absent_if { |value| value.nil? || value == false }
    subscribe { |connection| connection.session[:user_id] }
  end
end
```

If a page reads an undeclared non-absent `CurrentAttributes` or Warden identity,
Upkeep refuses live registration and reports `identity_setup_required` /
`unidentified_identity` rather than guessing.

### 5. Configure Delivery

Upkeep dispatches committed Active Record changes through a delivery adapter.
Production Rails apps should use Active Job so planning, rendering, and
broadcasting do not run in the writer's request:

```ruby
Upkeep::Rails.configure do |config|
  config.delivery_adapter = Rails.env.production? ? :active_job : :async
  config.delivery_queue = :upkeep_realtime
end
```

This uses the app's normal Active Job backend. With Sidekiq, set
`config.active_job.queue_adapter = :sidekiq`. With Solid Queue, set
`config.active_job.queue_adapter = :solid_queue` and run the Solid Queue worker.
Upkeep does not talk to Sidekiq or Solid Queue directly.

The queue backend and the WebSocket broadcast backend are separate:

| Job backend | ActionCable backend | Redis required? |
| --- | --- | --- |
| Sidekiq | Redis | yes |
| Sidekiq | Solid Cable | only for Sidekiq |
| Solid Queue | Solid Cable | no |
| Solid Queue | Redis | only for ActionCable |
| Active Job async | ActionCable async | no, development/test only |

ActionCable still needs a shared adapter in multi-process deployments because
the job worker may not be the process holding the browser's WebSocket. Redis,
Solid Cable, and PostgreSQL are shared ActionCable adapters; `async` is only
for one-process development and tests.

For debugging, set `config.delivery_adapter = :inline` inside
`Upkeep::Rails.configure` to run delivery immediately. `:async` keeps the
previous process-local batching behavior and is useful for tests or small local
development.

### 6. Render Normal Rails Views

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

### 7. Keep Write Paths Focused

Writes keep doing domain work:

```ruby
class CardsController < ApplicationController
  def update
    Card.find(params[:id]).update!(card_params)
    head :ok
  end
end
```

After the commit, Upkeep dispatches invalidation facts to the configured
delivery adapter. Active Job delivery selects matching subscriptions, rerenders
the narrowest proven target in the job worker, and sends Turbo Stream payloads
to the connected browsers.

## How Refresh Works

1. A successful HTML GET captures a rendered page.
2. The browser subscribes using the injected `upkeep-subscription-source`.
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
- Single-root fragment targets and legal render-site container targets.

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
- Declared Upkeep identities that map observed render-time values to
  ActionCable subscribe-time values.

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

Upkeep observes ambient state while rendering, but subscriber identity is
explicit. A page that reads `Current.user` is not automatically treated as a
user page. Declare the identity:

```ruby
Upkeep::Rails.configure do |config|
  config.identify :viewer, current: ["Current", :user] do
    subscribe { |connection| connection.current_user }
  end
end
```

The symbol, such as `:viewer`, names the identity component. Common components
are `:viewer`, `:account`, `:tenant`, `:organization`, `:role`, `:locale`, and
`:impersonator`. If a page depends on both `:viewer` and `:account`, the cable
subscription must match both before Upkeep authorizes the live stream.

A declared identity only partitions delivery when its captured value is present.
The default absence rule is `nil`; customize it with `absent_if` when your app
uses another sentinel. Upkeep records the absence decision at capture time, so
session and cookie identity values can remain fingerprinted instead of being
stored raw.

If a page never reads identity state, it can stay anonymous-public. Anonymous
subscribers with the same subscription shape can share compiled subscription
structure and update renders. Upkeep does not share initial response HTML.

Session, cookie, and request replay stores only observed values needed to rerun
the page. Unread session keys, cookies, and request headers are not copied into
the replay payload. Session and cookie reads become subscriber identity only
when declared with `config.identify`; otherwise they are ambient replay inputs
and do not authorize an ActionCable subscriber.

## Refused Boundaries

Upkeep distinguishes a refused boundary from a deoptimization.

A **refused boundary** means Upkeep cannot prove correctness. In
development/test, refused boundaries raise by default. In production, they warn,
emit `refused_boundary.upkeep`, and skip live registration for that boundary by
default:

```ruby
Upkeep::Rails.configure do |config|
  config.refused_boundary_behavior = :raise # or :warn
end
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

Structure app tests around behavior, not store internals:

- Most request/system tests can run with `config.upkeep.subscription_store =
  :memory`. Memory has the same public lifecycle as ActiveRecord: registration
  is fetchable immediately, lookup visibility starts on activation, touch
  updates liveness, unregister/prune remove lookup entries, and delivery uses
  the same planner surface.
- Keep a smaller ActiveRecord-backed integration slice for the production-only
  concerns: generated migration shape, schema validation, durable rows,
  reload/rehydration, async persistence, and cross-process lookup.
- Do not assert implementation details that are unique to one store unless the
  test is explicitly about that implementation. For app behavior, assert the
  marker, activation, streams, broadcasts, and rendered bytes.

Run the project test suite with the project Ruby:

```sh
mise exec -- ruby -S rake test
mise exec -- ruby bin/test
```

`bin/test` runs the gem tests, both maintained benchmark app test suites, and
the proof runner. The proof runner writes JSON reports to `results/`.

