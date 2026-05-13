# frozen_string_literal: true

require "test_helper"

class SubscriptionCard < ActiveRecord::Base
  self.table_name = "subscription_cards"

  def to_partial_path
    "subscription_cards/card"
  end
end

class SubscriptionCardsController < ActionController::Base
  def index
    @cards = SubscriptionCard.where(status: params.fetch(:status, "open")).order(:id)
    render template: "subscription_cards/index"
  end
end

class InvalidationPlannerTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call
    SubscriptionCardsController.view_paths = [resolver]

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :subscription_cards, force: true do |table|
        table.string :title, null: false
        table.string :status, null: false
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def test_collection_membership_change_uses_reverse_index_across_subscriptions
    create_subscription_card!("Plan")
    create_subscription_card!("Build")
    create_subscription_card!("Archived", status: "closed")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")
    register_controller_subscription(store, subscriber_id: "subscriber-b")

    Upkeep::Runtime::ChangeLog.reset
    create_subscription_card!("Review")

    plan = planner(store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal ["subscriber-a", "subscriber-b"], plan.targets.map(&:subscriber_id).sort
    assert_equal ["render_site"], plan.targets.map { |target| target.target.kind }.uniq
    assert_equal 2, plan.summary.fetch(:manifest_replay_targets)
    assert_equal 2, plan.matched_entries.size
    assert_operator store.summary.fetch(:reverse_index).fetch(:lookup_keys), :>, 0

    plan.targets.each do |target|
      rendered = target.render
      assert_includes rendered, "Review"
      refute_includes rendered, "Archived"
    end
  end

  def test_planning_emits_cost_notification
    create_subscription_card!("Plan")
    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    create_subscription_card!("Review")

    events = []
    subscription = ActiveSupport::Notifications.subscribe("plan.upkeep") { |event| events << event }

    plan = planner(store).plan(Upkeep::Runtime::ChangeLog.events)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription

    event = events.first
    assert event
    assert_equal 1, event.payload.fetch(:change_count)
    assert_equal plan.candidate_entries.size, event.payload.fetch(:candidate_entries)
    assert_equal plan.matched_entries.size, event.payload.fetch(:matched_entries)
    assert_equal plan.targets.size, event.payload.fetch(:targets)
    assert_equal ["render_site"], event.payload.fetch(:target_kinds)
    assert_equal plan.summary.fetch(:manifest_replay_targets), event.payload.fetch(:manifest_replay_targets)
    assert_equal({ "append" => 1 }, event.payload.fetch(:actions))
    assert_equal({}, event.payload.fetch(:deoptimizations))
  end

  def test_same_subscriber_same_identity_target_is_deduplicated
    card = create_subscription_card!("Plan")

    store = Upkeep::Subscriptions::Store.new
    2.times { register_controller_subscription(store, subscriber_id: "subscriber-a") }

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    plan = planner(store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal 1, plan.targets.size
    target = plan.targets.first
    assert_equal "subscriber-a", target.subscriber_id
    assert_equal "fragment", target.target.kind
    assert_equal "fragment:rails:subscription_cards/_card:subscription_cards:#{card.id}", target.target.id
    assert_includes target.render, "Plan v2"
  end

  def test_identity_partitioned_fragments_keep_distinct_payloads
    reset_domain_database
    store = Upkeep::Subscriptions::Store.new
    render_identity_subscription(store, subscriber_id: "Alice", user_name: "Alice")
    render_identity_subscription(store, subscriber_id: "Bob", user_name: "Bob")

    Upkeep::Runtime::ChangeLog.reset
    Upkeep::Domain::Card.find_by!(title: "Plan").update!(value: 90)

    plan = planner(store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal ["Alice", "Bob"], plan.targets.map(&:subscriber_id).sort
    assert_equal 1, plan.targets.map { |target| target.target.id }.uniq.size
    assert_equal 2, plan.targets.map(&:identity_signature).uniq.size

    rendered_by_subscriber = plan.targets.to_h { |target| [target.subscriber_id, target.render] }
    assert_includes rendered_by_subscriber.fetch("Alice"), "$90"
    assert_includes rendered_by_subscriber.fetch("Bob"), "Hidden"
    refute_includes rendered_by_subscriber.fetch("Bob"), "$90"

    identity_sources = store.fetch(plan.targets.first.subscription_id)
      .recorder
      .identity_profile(plan.targets.first.frame_id)
      .map { |dependency| dependency.fetch(:source).to_s }

    assert_includes identity_sources, "Current.user"
  end

  def test_current_user_record_change_targets_only_matching_subscriber
    reset_domain_database
    store = Upkeep::Subscriptions::Store.new
    render_identity_subscription(store, subscriber_id: "Alice", user_name: "Alice")
    render_identity_subscription(store, subscriber_id: "Bob", user_name: "Bob")

    Upkeep::Runtime::ChangeLog.reset
    Upkeep::Domain::User.find_by!(name: "Bob").update!(value_limit: 100)

    plan = planner(store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal ["Bob"], plan.targets.map(&:subscriber_id).uniq
    assert_operator plan.targets.size, :>, 0
    assert_empty plan.targets.select { |target| target.subscriber_id == "Alice" }
    assert plan.targets.any? { |target| target.render.include?("$80") }
  end

  def test_ambient_identity_dependencies_are_preserved_on_page_targets
    reset_domain_database
    store = Upkeep::Subscriptions::Store.new
    render_auth_subscription(store, subscriber_id: "Alice", user_name: "Alice")
    render_auth_subscription(store, subscriber_id: "Bob", user_name: "Bob")

    Upkeep::Runtime::ChangeLog.reset
    Upkeep::Domain::User.find_by!(name: "Alice").update!(name: "Alice Prime")

    plan = planner(store).plan(Upkeep::Runtime::ChangeLog.events)

    assert_equal ["Alice"], plan.targets.map(&:subscriber_id)
    assert_equal ["page"], plan.targets.map { |target| target.target.kind }
    assert_includes plan.targets.first.render, "Alice Prime"

    identity_sources = store.fetch(plan.targets.first.subscription_id)
      .recorder
      .identity_profile(plan.targets.first.frame_id)
      .map { |dependency| dependency.fetch(:source).to_s }

    assert_includes identity_sources, "current_attribute"
    assert_includes identity_sources, "session"
    assert_includes identity_sources, "cookie"
    assert_includes identity_sources, "request"
    assert_includes identity_sources, "warden_user"
  end

  private

  def planner(store)
    Upkeep::Invalidation::Planner.new(store: store)
  end

  def create_subscription_card!(title, status: "open")
    SubscriptionCard.create!(title: title, status: status)
  end

  def register_controller_subscription(store, subscriber_id:)
    _html, recorder = capture_controller_request("/cards?status=open")
    store.register(subscriber_id: subscriber_id, recorder: recorder)
  end

  def capture_controller_request(path)
    result, recorder = Upkeep::Runtime::Observation.capture_request do
      _status, _headers, body = SubscriptionCardsController.action(:index).call(Rack::MockRequest.env_for(path))
      [collect_body(body), Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def render_identity_subscription(store, subscriber_id:, user_name:)
    user = Upkeep::Domain::User.find_by!(name: user_name)
    result = renderer.render_request("boards/identity_collection", method(:domain_request), user: user)
    store.register(subscriber_id: subscriber_id, recorder: result.recorder)
  end

  def render_auth_subscription(store, subscriber_id:, user_name:)
    user = Upkeep::Domain::User.find_by!(name: user_name)
    result = renderer.render_request(
      "boards/auth_surfaces",
      method(:domain_request),
      user: user,
      session: { tenant_id: "tenant-#{subscriber_id.downcase}" },
      cookies: { theme: subscriber_id == "Alice" ? "light" : "dark" },
      request: { subdomain: subscriber_id.downcase },
      warden: { user: user },
      current_attributes: { account_id: "account-#{subscriber_id.downcase}", viewer_role: subscriber_id.downcase }
    )

    store.register(subscriber_id: subscriber_id, recorder: result.recorder)
  end

  def reset_domain_database
    Upkeep::Domain::Database.reset!
    Upkeep::Domain::Database.seed!
  end

  def domain_request
    board = Upkeep::Domain::Board.find_by!(name: "Launch")
    {
      board: board,
      cards: board.cards.order(:position)
    }
  end

  def renderer
    @renderer ||= Upkeep::Rendering::Engine.new
  end

  def collect_body(body)
    body.each.to_a.join
  ensure
    body.close if body.respond_to?(:close)
  end

  def resolver
    ActionView::FixtureResolver.new(
      "subscription_cards/index.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "subscription_cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "subscription_cards/_card.html.erb" => <<~ERB
        <li id="subscription_card_<%= card.id %>">
          <span class="title"><%= card.title %></span>
          <span class="status"><%= card.status %></span>
        </li>
      ERB
    )
  end
end
