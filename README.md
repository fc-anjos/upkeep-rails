# Upkeep Rails

Rails-native runtime for implicit reactive rendering.

Upkeep Rails observes ordinary Rails requests, Action View renders, Active
Record reads and writes, and request identity surfaces. A successful HTML GET
records a render graph and registers a subscription. Later Active Record commits
select affected graph frames and deliver Turbo Stream payloads through
ActionCable.

The design goal is Rails-shaped DX: render normal Rails views, mutate normal
Active Record models, and let the runtime derive dependency and identity inputs
from the framework surfaces it observes. There is no query catalog, no
`watch`/`track` DSL, and no host-maintained list of identity dimensions.

## Current Integration Contract

The published Rails package is the app-facing runtime for Upkeep. It is tested
against the in-repo benchmark apps and exposes a small integration contract:

- `gem "upkeep-rails", require: "upkeep"`
- `bin/rails generate upkeep:install`
- `config.upkeep.enabled`
- `config.upkeep.subscription_store = :active_record`
- the `Upkeep::Rails::Cable::Channel` ActionCable channel
- the `upkeep_subscriptions` and `upkeep_subscription_index_entries` tables
- the generated browser subscription bootstrap
- `Upkeep::Rails::Testing` for integration tests
- ordinary Rails render, request, identity, and Active Record behavior

Everything under `Upkeep::Runtime`, `Upkeep::Dependencies`,
`Upkeep::Invalidation`, `Upkeep::Subscriptions`, `Upkeep::Delivery`,
`Upkeep::DAG`, probes, proofs, and benchmark harness code is internal.

## Start Here


## How It Feels

Controllers keep loading state the Rails way:

```ruby
class BoardsController < ApplicationController
  def show
    @board = Board.find(params[:id])
    @cards = @board.cards.order(:position)
  end

  def update_card
    @board.cards.find(params[:card_id]).update!(card_params)
    head :ok
  end
end
```

Views keep rendering normal templates and partials:

```erb
<section id="cards">
  <%= render partial: "cards/card", collection: @cards, as: :card %>
</section>
```

When the page renders, Upkeep attaches frame and dependency nodes to the current
request graph. When a card update commits, Upkeep walks from changed Active
Record dependencies to affected frames and renders the narrowest eligible
target for each subscriber.

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

Identity dependencies:

- `ActiveSupport::CurrentAttributes` reads.
- Warden and Devise user reads through Warden.
- Session and cookie reads.
- Request values such as host, path, params, user agent, and remote IP.
- ActionCable connection identifiers.

## Install

Add the gem to a Rails app:

```ruby
gem "upkeep-rails", require: "upkeep"
```

Run the installer in a Rails app:

```sh
bin/rails generate upkeep:install
bin/rails db:migrate
```

The generator creates subscription tables, writes `config/initializers/upkeep.rb`,
mounts ActionCable when needed, pins Turbo and ActionCable for importmap apps,
and imports the browser bootstrap from `app/javascript/application.js`.

Production subscription storage is explicit. `:active_record` is the supported
production store because Upkeep needs a queryable reverse index shared across
Puma workers. `:memory` is available only as an explicit development/test
choice. Delivery still flows through ActionCable, so multi-worker deployments
also need a shared ActionCable adapter such as Redis or Solid Cable.

## Delivery Boundary

The runtime injects a `<script data-upkeep-subscription>` marker into successful
HTML GET responses and registers an `Upkeep::Rails::Cable::Channel`
subscription record. The generated browser bootstrap reads those markers,
subscribes over ActionCable, and appends received Turbo Stream payloads to the
document.

## Run

Use the project Ruby:

```sh
mise exec -- ruby -S rake test
mise exec -- ruby bin/test
```

`bin/test` runs the gem tests, both maintained benchmark app test suites, and
the proof runner. The proof runner writes JSON reports to `results/`.
