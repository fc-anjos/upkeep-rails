# Upkeep Rails

Upkeep automatically syncs record changes to browsers showing affected data. When you save a record, it figures out which rendered pages depend on it and sends Turbo Streams to the right subscribers.

Instead of naming stream targets in your controller:

```ruby
class CardsController < ApplicationController
  def create
    @card = Card.create!(card_params)
    respond_to { |f| f.turbo_stream }
  end
end
```

```erb
<%= turbo_stream.append "cards", partial: "card", locals: { card: @card } %>
```

You just save the record:

```ruby
class CardsController < ApplicationController
  def create
    Card.create!(card_params)
    head :no_content
  end
end
```

Upkeep observed which records the initial GET read, so it knows the page depends on the card table. When the create commits, it broadcasts to the right browsers automatically.

## Install

Add the gem to your Gemfile:

```ruby
gem "upkeep-rails"
```

Run the installer:

```sh
bin/rails generate upkeep:install
bin/rails db:migrate
```

This creates the subscription tables, writes an initializer, mounts ActionCable if needed, and imports the browser client.

Requirements: Ruby 3.2+, Rails 7.1+, Turbo 2.0+.

## Configure runtime

The installer creates `config/initializers/upkeep.rb`. Most projects work with the defaults, but you can customize:

```ruby
Upkeep::Rails.configure do |config|
  config.subscription_store = :active_record  # :memory for tests
  config.deliver_inline = false  # true for tests/console
  config.refused_boundary_behavior = :warn  # :raise in strict mode
end
```

**Subscription store:** Use `:memory` for test suites. Use `:active_record` for production—it stores subscriptions durably across restarts.

**Delivery mode:** Upkeep broadcasts from a background dispatcher in the same process that performed the write. For tests and console sessions where you want synchronous behavior, set `deliver_inline = true`.

**Subscription lifecycle:** Subscriptions clean themselves up. A clean disconnect deletes the subscription immediately; abandoned subscriptions (crashed browsers, dropped connections) are trimmed opportunistically in small batches once they go untouched for `config.subscription_ttl` (default 24 hours); and connected pages send a liveness heartbeat every 20 minutes, so a long-lived open tab is never pruned. Adjust `subscription_ttl` to control how long abandoned subscriptions may linger.

**Multi-process deployments:** If you run multiple Puma workers, you need a cross-process cable adapter so broadcasts reach all processes. We recommend `solid_cable`.

## Configure identity

If your pages depend on the current user, account, or any viewer-specific value, tell Upkeep how to match that between render time and subscription time.

First, declare the identity in the initializer:

```ruby
Upkeep::Rails.configure do |config|
  config.identify :viewer, current: ["Current", :user] do
    subscribe { |connection| connection.current_user }
  end
end
```

Then make sure your cable connection exposes it:

```ruby
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = User.find_by(id: request.session[:user_id])
    end
  end
end
```

Pick the declaration that matches how your render path reads the identity:

| Render path | Configuration | Subscribe returns |
| --- | --- | --- |
| `Current.user` | `current: ["Current", :user]` | `connection.current_user` |
| Devise/Warden | `warden: :user` | `connection.current_user` |
| `session[:user_id]` | `session: :user_id` | `connection.session[:user_id]` |
| `cookies[:account_id]` | `cookie: :account_id` | `connection.cookies[:account_id]` |

For logged-out pages where `nil` is a valid identity, declare how to recognize "absent":

```ruby
config.identify :viewer, session: :user_id do
  absent_if { |value| value.nil? || value == false }
  subscribe { |connection| connection.session[:user_id] }
end
```

If your render path reads an undeclared identity value (like a `CurrentAttributes` field), Upkeep will refuse to register that page for live updates rather than guess who should receive the broadcast.

## When Upkeep can't track your data

Upkeep needs to understand your queries to know which records affect which renders. It can't work with raw SQL strings, opaque joins, or objects that aren't tied back to the database schema.

These queries will cause Upkeep to refuse the page:

```ruby
# Raw SQL predicates
Story.where("score >= 0")
Story.order("created_at DESC")

# Opaque joins
User.joins("INNER JOIN posts ON ...")

# From sources that aren't table names
Story.from("(SELECT * FROM stories WHERE ...)")
```

Rewrite them using Rails or Arel:

```ruby
Story.where(Story.arel_table[:score].gteq(0))
Story.order(created_at: :desc)
```

By default, Upkeep raises an error in development and test, and logs a warning in production (but still renders the page). You can change this behavior:

```ruby
Upkeep::Rails.configure do |config|
  config.refused_boundary_behavior = :warn  # or :raise
end
```

For queries that genuinely can't be made structural—like full-text search backed by raw `tsvector`—opt the request out entirely instead:

```ruby
class StoriesController < ApplicationController
  def index
    @stories = params[:query].present? ? Story.search(params[:query]) : Story.all
  end

  private

  def upkeep_reactive_request?
    return false if params[:query].present?
    super
  end
end
```

The request still renders normally. Upkeep just doesn't register subscriptions or analyze the boundary. The unfiltered view (without a query param) stays reactive.

**General rule:** if Rails or Arel can describe the table, columns, predicates, and sort order, Upkeep can track it. If the query logic lives inside a SQL string, Upkeep will refuse the page.

## How Upkeep compares to Turbo Streams

With vanilla Turbo Streams, the write action names which parts of the UI to refresh. You maintain the list of targets as your UI evolves:

```ruby
class CardsController < ApplicationController
  def create
    @board = Board.find(params[:board_id])
    @card = @board.cards.create!(card_params)
    
    respond_to do |format|
      format.turbo_stream
    end
  end
end
```

```erb
<%= turbo_stream.append "cards", partial: "card", locals: { card: @card } %>
<%= turbo_stream.update "board_open_count", @board.open_count %>
```

This couples the write path to the current UI. When you add a sidebar showing the same board, or a filter that depends on card status, you revisit the controller and stream template.

With Upkeep, the write path just saves the record. The subscription comes from the read:

```ruby
class CardsController < ApplicationController
  def create
    Board.find(params[:board_id]).cards.create!(card_params)
    head :no_content
  end
end
```

Upkeep observed which records your initial GET read, so it knows which renders care about this card. It broadcasts to those subscribers automatically. You add a sidebar or filter without touching the write path.

The tradeoff: Turbo Streams let you control exactly what gets broadcast and how it's rendered (you might patch a counter without rerendering the list). Upkeep derives updates from renders it observed, so it's narrower but also more opinionated about safety.

| Concern | Turbo Streams | Upkeep |
| --- | --- | --- |
| Write path | Declares targets and templates | Just commits the record |
| Boundary discovery | You maintain it | Upkeep infers from renders |
| Unsafe broadcasts | You decide how broad | Upkeep refuses unsafe patterns |
| Render changes | Update the stream template | Happens automatically |
| Full control | Yes | No, but less coupling |

See [How Upkeep Works](docs/how-it-works.md) for details on the runtime model.
