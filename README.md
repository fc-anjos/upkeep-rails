# Upkeep Rails

## 0. Quick Intro

Upkeep Rails keeps ordinary Rails pages fresh when the data, request inputs, or
identity values they used change.

A successful HTML GET renders through Rails as usual. Upkeep records the
templates, records, relations, request values, and identity values that shaped
the response. Later, an Active Record commit emits facts about what changed.
Upkeep matches those facts to affected rendered frames and delivers ordinary
Turbo Stream updates over ActionCable.

The design goal is Rails-shaped DX: controllers load state, views render ERB,
models commit writes, and Upkeep derives the reactive boundary from the Rails
surfaces it observes. There is no query catalog and no `watch` or `track` DSL.

For the deeper runtime model, see [How Upkeep Works](docs/how-it-works.md).

## 1. Upkeep vs Vanilla Turbo

With vanilla Turbo Streams, write paths often need to name the UI they refresh:

```ruby
# app/controllers/cards_controller.rb
class CardsController < ApplicationController
  def create
    @board = Board.find(params[:board_id])
    @card = @board.cards.new(card_params)

    if @card.save
      @open_card_count = @board.cards.open.count

      respond_to do |format|
        format.turbo_stream
      end
    else
      render :new, status: :unprocessable_entity
    end
  end
end
```

```erb
<%# app/views/cards/create.turbo_stream.erb %>
<%= turbo_stream.append "cards",
  partial: "cards/card",
  locals: { card: @card } %>

<%= turbo_stream.update "open_card_count", @open_card_count %>
```

That follows the standard Turbo Stream shape and avoids a page visit for the
submitting browser. The tradeoff is that the write path is still coupled to the
current UI. Adding another dependent page, sidebar, filter, or counter usually
means revisiting stream templates, controller assignments, callbacks, or
broadcasts.

With Upkeep, the controller can acknowledge the successful write without naming
stream targets:

```ruby
class CardsController < ApplicationController
  def create
    board = Board.find(params[:board_id])
    board.cards.create!(card_params)

    head :no_content
  end
end
```

The submitting Turbo request gets a successful empty response, so it does not
perform a page visit. The GET that rendered the page already recorded the
rendered dependencies. When the commit lands, Upkeep selects affected
subscribers and sends Turbo Streams to the browsers that need them. Validation
and error rendering stay ordinary application code; the live update path does
not need to name DOM targets.

| Concern | Vanilla Turbo | Upkeep |
| --- | --- | --- |
| Write path | Names stream targets, partials, counters, or pages. | Commits domain changes. |
| Read path | Ordinary Rails render. | Ordinary Rails render, captured during HTML GETs. |
| Browser update | Turbo Streams or page refresh. | Turbo Streams or page refresh. |
| Boundary | App declares it in stream templates, callbacks, or broadcasts. | Upkeep derives it from rendered Rails surfaces when it can prove safety. |
| Unsafe shape | App decides how broad to broadcast. | Upkeep raises or warns and refuses the live boundary. |

## 2. Install

Add the gem:

```ruby
gem "upkeep-rails"
```

Run the installer:

```sh
bin/rails generate upkeep:install
bin/rails db:migrate
```

The generator creates subscription tables, writes
`config/initializers/upkeep.rb`, mounts ActionCable when needed, pins Turbo and
ActionCable for importmap apps, and imports the browser bootstrap from
`app/javascript/application.js`.

The browser bootstrap is vendored into the host app at
`app/javascript/upkeep/subscription.js`. After upgrading `upkeep-rails`, rerun
the installer or compare that file with the generated template.

Requirements: Ruby 3.2+, Rails 7.1+, and Turbo 2.0+.

## 3. Configure Runtime

The generated initializer is the normal place to configure Upkeep:

```ruby
# config/initializers/upkeep.rb
Upkeep::Rails.configure do |config|
  app_config = Rails.application.config.upkeep

  config.enabled = app_config.fetch(:enabled, true)
  config.subscription_store = app_config.fetch(:subscription_store, Rails.env.test? ? :memory : :active_record)
  config.delivery_adapter = app_config.fetch(:delivery_adapter, Rails.env.production? ? :active_job : :async)
  config.delivery_queue = app_config.fetch(:delivery_queue, :upkeep_realtime)
end
```

Use `:active_record` for durable subscription storage in production. The
generated migration creates the required tables. Use `:memory` for most request
and system tests, and keep at least one app or CI path on `:active_record` when
you want to exercise durable rows, schema checks, reload, and cross-process
lookup.

Production apps should use Active Job for delivery so planning, rerendering,
and broadcasting do not run in the writer's request:

```ruby
Upkeep::Rails.configure do |config|
  config.delivery_adapter = Rails.env.production? ? :active_job : :async
  config.delivery_queue = :upkeep_realtime
end
```

Configure the app's Active Job backend normally, such as Solid Queue, Sidekiq,
or GoodJob. ActionCable still needs a shared adapter in multi-process
deployments because a job worker may not be the process holding the browser's
WebSocket. Redis, Solid Cable, and PostgreSQL are shared ActionCable adapters.

For local debugging, set `config.delivery_adapter = :inline` to run delivery
immediately.

## 4. Configure Identity

Pages that depend on a user, account, tenant, locale, or other viewer-specific
value need an explicit identity bridge.

The render side tells Upkeep which value the HTML render read. The subscribe
side tells Upkeep how the ActionCable connection proves the same value when the
browser subscribes.

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

Choose the source keyword from the API your render path actually reads:

| Render path reads | Declare | Subscribe side returns |
| --- | --- | --- |
| `Current.user` | `current: ["Current", :user]` | the same user, usually `connection.current_user` |
| Devise or Warden user reads | `warden: :user` | the same Devise user, usually `connection.current_user` |
| `session[:user_id]` | `session: :user_id` | `connection.session[:user_id]` |
| `cookies[:account_id]` | `cookie: :account_id` | `connection.cookies[:account_id]` |

By default, `nil` means a declared identity boundary is absent. That keeps
logged-out pages anonymous-public even when a layout checks `Current.user` or
`session[:user_id]`. If your app has another "not signed in" sentinel, declare
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
Upkeep refuses live registration instead of guessing who may receive updates.

## 5. Opaque Values, DX, and Refactors

Upkeep only registers live boundaries it can prove. It needs to know which
future write facts can make a rendered result stale, which target can be
rerendered or patched, and which observed identity inputs decide whether the
result can be shared.

`Opaque` means application code used something real, but Rails did not expose
enough structure for Upkeep to answer those questions. Common examples are raw
SQL predicates, raw joins, raw `from` sources, unknown table aliases, opaque
order expressions, and render locals that cannot be rebuilt later.

The DX is intentionally fail-fast:

- development and test raise by default
- production warns and skips live registration by default
- `refused_boundary.upkeep` is emitted for instrumentation
- Upkeep does not widen to a broad unsafe dependency

You can choose the behavior explicitly:

```ruby
Upkeep::Rails.configure do |config|
  config.refused_boundary_behavior = :raise # or :warn
end
```

Most refactors are normal Rails cleanup. Prefer hash conditions and symbolic
orders when they express the query:

```ruby
# Before: opaque SQL string order
Story.order("stories.created_at DESC")

# After: structural Rails order
Story.order(created_at: :desc)
```

Use Arel when the query needs an operator or correlated condition that hash
syntax cannot express:

```ruby
# Before: opaque SQL string predicate
Story.where("score >= 0")

# After: structural Arel predicate
Story.where(Story.arel_table[:score].gteq(0))
```

```ruby
# Before: opaque correlated SQL
HiddenStory.where(Arel.sql("hidden_stories.story_id = stories.id"))

# After: structural correlated predicate
HiddenStory.where(
  HiddenStory.arel_table[:story_id].eq(Story.arel_table[:id])
)
```

For replay values, keep frame locals and render options to records, relations,
arrays, hashes, literals, and observed request, session, or cookie values. Avoid
passing procs, IO handles, open clients, or process-local objects into live
render boundaries.

Some boundaries are intractable on purpose. A full-text search backed by raw
`tsvector`/`tsquery` SQL has no structural column coverage to prove, and
rewriting it would defeat the search. When a request should not be made
reactive at all, opt it out instead of refusing a boundary mid-render. Override
`upkeep_reactive_request?` in the controller and return `false` for those
requests:

```ruby
# app/controllers/stories_controller.rb
def index
  @stories = params[:query].present? ? Story.search(params[:query]) : Story.recent
end

private

# Search results use a raw full-text scope Upkeep cannot prove; render them
# normally but do not register them for live refresh.
def upkeep_reactive_request?
  return false if params[:query].present?

  super
end
```

An opted-out request still runs the action and renders the page; Upkeep simply
records no subscription, injects no source, and analyzes no boundary — so an
opaque relation on that request neither raises nor warns. The unfiltered page
(no `query`) stays reactive. Reach for this only when the boundary is
genuinely unprovable; prefer the structural refactors above whenever the shape
*can* be made explicit.

The rule of thumb: when Rails and Arel can describe the table, column,
predicate, order, and value shape, Upkeep can usually reason about it. When the
shape is hidden inside a string or arbitrary Ruby object, Upkeep refuses the
live boundary and tells you where to make the shape explicit.
