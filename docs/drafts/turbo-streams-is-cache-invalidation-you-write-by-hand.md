# Live Rails pages without writing broadcasts

---

A user posts a comment. Easy: `@comment.save`, redirect, done. Then someone asks for it to show up live, and the Turbo docs have you covered: add `broadcasts_to :post` and you're on the air. Then the comment count in the sidebar goes stale, so you add a broadcast for that. Then the moderation queue needs one. Then the author's profile page, which shows their latest activity. Six months later the `Comment` model broadcasts to four streams, and there's a comment in the code that says `# don't remove, the dashboard breaks`.

If any of this sounds familiar, you're in good company. Nobody plans this; every one of those broadcasts was the reasonable next step on the day it was written. In this post we'll look at why this pattern decays no matter how careful you are, and we'll introduce [Upkeep](https://github.com/fc-anjos/upkeep-rails), an open source gem we built that takes a different approach: instead of you telling Rails which pages a write affects, it watches your pages render and works that out on its own.

## The list nobody checks

Here's the standard Turbo Streams shape, straight from any tutorial. The write action names the parts of the UI it affects:

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

This works, and it ships. Now let's look closer at what those stream lines really are. Each one is a rule, and the rule says: when a card changes, this part of this page needs updating. You wrote that rule by hand, and here's the trouble: the app will happily let it go stale. Suppose a teammate adds an open-card count to the dashboard. It renders correctly, it ships, and it's out of date within the hour, because nobody knew the dashboard now needed a broadcast too. No test fails, since stale pages don't raise. Sooner or later a bug report arrives that says "sometimes the dashboard is behind," and those reports keep coming, because nothing in the app checks that the broadcast list still matches the UI.

The decay runs the other way too. Someone redesigns the board page and removes the open count, and the `turbo_stream.update "board_open_count"` line stays behind, broadcasting into an element that no longer exists. Rails will happily verify your routes, your migrations, and even your N+1 queries if you install a gem for it. This list, though, has no verifier at all.

If the pattern sounds familiar beyond Turbo, it should: this is cache invalidation. A hand-maintained set of "when X changes, Y is stale" rules is exactly the thing we all agreed was one of the two hard problems, and fragment caching moved away from it years ago with key-based expiration, precisely because hand-written invalidation doesn't survive contact with a changing codebase. Live updates are the same problem in a party hat.

There's also a second, trickier version of this problem: a broadcast doesn't just need the right target, it needs the right audience. If a partial renders differently for an admin than for a visitor, sending one viewer's HTML to everyone on the stream is a leak, and hand-written broadcasting leaves that entirely up to you. Keep this one in mind, because it comes back later. For now, let's stay with staleness, and with the question we kept coming back to while building live features: what if these rules could be derived from the pages themselves, instead of written by hand?

## Deriving the rules from renders

That's what Upkeep does. When a page renders during an ordinary GET request, Upkeep watches: which records were read, which columns, what query produced that list of cards. It stores that as a subscription for the page. Later, when a write commits, it checks the write against the stored subscriptions and sends Turbo Streams to exactly the browsers whose pages went stale. The create action is left with one job:

```ruby
class CardsController < ApplicationController
  def create
    Board.find(params[:board_id]).cards.create!(card_params)
    head :no_content
  end
end
```

The stream template is gone, and so is the `broadcasts_to` line in the model. Upkeep already knows the targets, because it saw them render: it plans an `append` into the card list it observed and an `update` for the count it observed, and it delivers them to the subscribed browsers when the create commits.

And when your teammate adds that open-card count to the dashboard next month? The dashboard's next render records the new dependency, and the page is live from its first request. Nobody had to remember anything, and that's the whole idea: the dependency list is rebuilt from real renders, so it can't drift out of date.

Getting started is the usual two steps:

```ruby
gem "upkeep-rails"
```

```sh
bin/rails generate upkeep:install
bin/rails db:migrate
```

The installer creates the subscription tables, writes an initializer, and imports the browser client. Requirements are Ruby 3.2+, Rails 7.1+, and Turbo 2.0+.

### Declaring identities: the one new concept

If your pages depend on the current user, there's one more step, and it's fair to present it as the one genuinely new concept Upkeep asks you to learn. With hand-written broadcasts, Rails never asks which session or `Current` values shaped a page, because you're the one deciding who gets each broadcast. Upkeep makes that decision for you, and it won't make it on a guess. So the mapping between what the page read at render time and what the ActionCable connection can prove at subscribe time has to come from you.

Let's set it up for a Devise app. Devise authenticates through Warden, so we declare a `:viewer` identity backed by the Warden user:

```ruby
# config/initializers/upkeep.rb
Upkeep::Rails.configure do |config|
  config.identify :viewer, warden: :user do
    subscribe { |connection| connection.current_user }
  end
end
```

Reading it as a sentence: "when a render reads the Warden `:user`, deliver its updates only to subscribers whose connection presents the same `current_user`." The `subscribe` block is evaluated against your ActionCable connection, so the connection needs to expose that value, which is the standard Devise-and-ActionCable setup you may already have:

```ruby
# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = env["warden"].user
    end
  end
end
```

One more wrinkle worth handling on day one: logged-out pages. When nobody is signed in, the Warden read comes back `nil`, and Upkeep needs to know whether `nil` means "a viewer we couldn't identify" (don't share!) or "anonymous public" (share freely). You tell it with `absent_if`:

```ruby
config.identify :viewer, warden: :user do
  absent_if { |value| value.nil? }
  subscribe { |connection| connection.current_user }
end
```

With that in place, your public pages get the cheap shared broadcasting from the previous section, and your signed-in pages get updates scoped to the right viewer. If a page reads an identity you haven't declared, Upkeep refuses to make that page live and names the missing declaration, so a forgotten mapping shows up as a development-time message rather than as someone else's HTML.

For a typical Devise app, this is a few lines written once. If your app derives viewer state in several creative ways, budget a real hour for it, and let the refusal messages point you to each source that needs declaring. The README covers the other three shapes: `Current` attributes, session keys, and cookies.

### Where does all this live?

A reasonable question at this point: Upkeep is remembering what every open page depends on, so where does that memory go, and what keeps it from growing forever?

The installer's migration creates three tables. `upkeep_subscriptions` holds one row per subscribed page, with the page's dependency graph serialized as JSON. `upkeep_subscription_index_entries` is the reverse index that write matching runs against: table names, columns, and predicate digests, laid out so a committed write can find its candidate subscriptions with an indexed lookup instead of scanning graphs. And `upkeep_subscription_shape_index_entries` deduplicates that index across identical pages, so ten thousand people looking at the same public feed share index rows instead of multiplying them. The subscription row is written when the page renders, and the index rows are written when the browser's ActionCable connection comes up, which means half-loaded pages that never connect don't clutter the index.

Cleanup follows the same pattern Solid Cache and Solid Cable use for their tables: it rides on the gem's own traffic, with no scheduler for you to remember. Three rules keep the tables bounded. When a browser disconnects cleanly, its subscription row is deleted on the spot. While a browser stays connected, its channel touches the subscription every twenty minutes, so a dashboard left open for a week is never mistaken for garbage. And everything that hasn't been touched within the TTL, twenty-four hours by default via `config.subscription_ttl`, gets collected opportunistically: every hundredth registration prunes one bounded batch of expired rows, wrapped so a cleanup hiccup can never fail a request. Crashed tabs and dropped connections leave rows behind, and the next day's traffic quietly sweeps them out.

Deploys get a tidy answer from machinery you've already seen. Subscription shapes carry the gem version in their digest, and shared stream names carry a digest of the render recipe, so a subscription stored under last week's templates simply stops matching anything the new code broadcasts. It can't replay an old template or deliver against a renamed target; the worst it can do is nothing, until the TTL collects it. Refuse rather than guess, applied to time.

## Wait, doesn't automatic invalidation always guess wrong?

Fair question! Automatic invalidation has a deserved reputation: systems that guess which pages depend on which data tend to guess wide, refresh too much, and eventually get turned off. So let's spend a minute on why Upkeep can afford to be precise.

The trick is that Active Record queries are, most of the time, structured data. Rails builds them as Arel, and Arel can be read like a description: which table, which columns, which predicates, which ordering. Take a page that renders this:

```ruby
@cards = Card.where(status: "open").order(:position)
```

Upkeep reads the structure behind that relation and stores what the query means. An insert affects this page only if the new row's status is open. An update matters only if it touched `status` or `position`, or belongs to a row that's already rendered. Any other write to the cards table can churn all day without producing a single broadcast, because the stored structure proves the page doesn't care.

Let's peek under the hood, because this part is less magical than it sounds. At render time, Upkeep walks the Arel tree of every relation the page reads. The walker is a plain old `case` statement over node types (here it is from the gem's source, trimmed down):

```ruby
# lib/upkeep/active_record_query.rb
def walk(value, source: false)
  case value
  when Arel::Attributes::Attribute
    attribute(value)
  when Arel::Nodes::Equality
    walk(value.left, source: source)
    walk(value.right, source: source) if value.right.is_a?(Arel::Attributes::Attribute)
  when Arel::Nodes::HomogeneousIn
    walk(value.attribute, source: source)
  when Arel::Table
    table(value.name)
  # ... more structural node types ...
  when Arel::Nodes::StringJoin
    opaque_table!("raw SQL join")
  when Arel::Nodes::BoundSqlLiteral, Arel::Nodes::SqlLiteral
    source ? opaque_table!("raw SQL source") : opaque_column!("raw SQL predicate or order expression")
  end
end
```

Both halves of the story are visible in one screen. Structural nodes like `Equality` and `Table` contribute columns and tables to the page's dependency record, while a `SqlLiteral` or a string join lands in an `opaque_table!` branch, and that's the refusal we'll get to in a moment.

The other half of the mechanism runs at write time. Every stored collection dependency knows how to answer one question about a committed change, and the method that answers it fits on a napkin:

```ruby
# lib/upkeep/dependencies.rb
def matches_change?(change)
  return false unless table_columns.key?(change.fetch(:table))

  predicate_match = predicate_match(change)
  return predicate_match unless predicate_match == UNKNOWN

  return true if create_change?(change)
  return true if delete_change?(change)

  table_columns.fetch(change.fetch(:table)).intersect?(change.fetch(:changed_attributes, []))
end
```

Reading it top to bottom: a write to a different table never matches; if the stored predicate can decide (the new row's `status` is `"open"`, or it isn't), its answer wins; when the predicate can't decide, creates and deletes match because they can change membership, and updates match only if the changed columns overlap the ones this page depends on. That last line is the "churn all day" guarantee from a moment ago, as one `intersect?` call. When a write does match, Upkeep picks the narrowest update it can justify: an `append` for a new member, a `replace` for a changed one, and when the narrow proof isn't available, a broader but still proven re-render of the enclosing container.

Now for the important part: what happens when the query isn't structured data?

```ruby
Story.where("score >= 0")
User.joins("INNER JOIN posts ON ...")
```

Rails hands these to the database as opaque strings, so there's no structure left for Upkeep to read. Here Upkeep makes the call that shapes the whole tool: it declines to track that page. It raises in development so you find out right away, warns in production, and the page renders as ordinary, perfectly functional, non-live HTML. Often the fix is a one-line rewrite into something structural, like `Story.where(Story.arel_table[:score].gteq(0))`. Sometimes there is no structural rewrite, with full-text search against a raw `tsvector` being the classic case, and for those you opt the request out and keep the rest of the page reactive.

We'd rather give you a page that's honestly static than one that's confidently wrong. A hand-written broadcast that's out of date fails silently in production, and we've all seen how vague those bug reports get. A derived rule that can't be proven fails loudly, at development time, with a message that tells you which query to fix.

## The bonus we didn't expect: fan-out gets cheap

We built the proof machinery for correctness, and then it handed us a performance feature.

Think about the pages where live updates matter most: feeds, boards, leaderboards, dashboards. Lots of people staring at the same data. With hand-written broadcasting, the safe general pattern is to do the rendering work per stream, because nothing in the app can tell whether two subscribers are seeing identical HTML. The fan-out cost grows with your audience.

Upkeep can tell. Identity reads, meaning `Current.user`, Warden, session, and cookies, are part of what it records at render time, and so is their absence. A page that read no viewer-specific data is provably public, and "provably" is doing real work in that sentence. Here's the method that decides, straight from the gem:

```ruby
# lib/upkeep/shared_streams.rb
def identity_signature_for(graph, frame_id)
  identity_dependencies = graph.contained_node_ids(frame_id)
    .flat_map { |owner_id| graph.dependencies_for(owner_id) }
    .select { |dependency| Dependencies.partitioning_identity?(dependency) }
    .uniq(&:cache_key)
  return "public" if identity_dependencies.empty?

  Digest::SHA256.hexdigest(identity_dependencies.map(&:identity_key).sort_by(&:inspect).inspect)[0, 16]
end
```

It gathers every identity read recorded under a frame during rendering. If the list is empty, the frame is public, and public frames with the same render recipe hash to the same shared stream name. A provably public page has a pleasant property: every subscriber is seeing the same bytes. So when the data changes, Upkeep renders the update once and broadcasts it once, whether twelve browsers are watching or ten thousand.

## What Upkeep refuses to do

A tool that promises to refuse rather than guess owes you the list of what it refuses. Here it is.

| It can't track                                                                        | Because                                                                                 | So                                                                                                   |
| ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Opaque relations: raw SQL predicates, raw joins, raw `from`, opaque order expressions | Rails no longer exposes enough structure to prove table, column, and predicate coverage | The boundary is refused and the page renders as ordinary HTML                                        |
| Reads from Redis, HTTP APIs, files, globals, memoized service state                   | Active Record commit facts can't select these reads                                     | They aren't live dependencies; a replay triggered by something else will pick up their current value |
| Writes that bypass Active Record: direct connection SQL, other datastores             | Without a write fact there's nothing to match against stored subscriptions              | No refresh is scheduled from that write                                                              |
| Viewer-specific pages whose identity you haven't declared                             | Upkeep won't infer who should receive HTML from naming conventions                      | Live registration is refused rather than risking the wrong browser                                   |
| Templates that fail Herb's strict ERB parse                                           | Narrow update targets are derived from template structure                               | You get broad page-level updates and a diagnostic instead of surgical ones                           |

Every row is the same decision applied to a different surface: where correctness can't be proven, the page behaves like the plain Rails HTML it always was. One distinction worth knowing before you read your logs: a _deoptimization_ means Upkeep found a broader target it can still prove, so the page stays live with a coarser update, while a _refusal_ means the page isn't live at all. The diagnostics tell you which one you got, and why.

## Enjoy deleting that comment

This post started with a `# don't remove, the dashboard breaks` comment guarding four hand-written broadcasts. With subscriptions derived from renders, that comment has nothing left to protect. Install the gem, take the broadcasts out, save a record, and watch the right pages update on their own.

```sh
bin/rails generate upkeep:install
bin/rails db:migrate
```

And the audience problem from earlier? Upkeep records every identity read a page makes, including `Current.user`, Warden, session, and cookies, and only delivers an update to subscribers who can prove the same identity over ActionCable. If a page depends on an identity you haven't declared, it refuses to make that page live rather than send viewer-specific HTML to the wrong browser.

---

_Upkeep is MIT-licensed and lives at [github.com/TODO-repo-link](https://github.com/TODO-repo-link). Issues, questions, and opaque-query war stories are all welcome._
