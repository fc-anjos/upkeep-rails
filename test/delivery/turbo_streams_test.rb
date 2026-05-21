# frozen_string_literal: true

require "test_helper"

class DeliveryCard < ActiveRecord::Base
  self.table_name = "delivery_cards"

  def to_partial_path
    "delivery_cards/card"
  end
end

class DeliveryCardsController < ActionController::Base
  def index
    cards = DeliveryCard.where(status: params.fetch(:status, "open"))
    @cards = case params[:order]
    when "title"
      cards.order(:title)
    when "title_desc"
      cards.order(title: :desc)
    else
      cards.order(:id)
    end
    @cards = @cards.limit(params[:limit].to_i) if params[:limit]
    render template: "delivery_cards/index"
  end

  def titles
    @titles = DeliveryCard.where(status: params.fetch(:status, "open")).pluck(:title)
    render template: "delivery_cards/titles"
  end
end

class TurboStreamsDeliveryTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call
    DeliveryCardsController.view_paths = [resolver]

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :delivery_cards, force: true do |table|
        table.string :title, null: false
        table.string :status, null: false
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def test_public_fragment_payload_is_shared_when_bytes_match
    card = create_delivery_card!("Plan")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")
    register_controller_subscription(store, subscriber_id: "subscriber-b")

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    batch = delivery.build(plan_for(store))

    assert_equal 1, batch.streams.size
    stream = batch.streams.first
    assert_equal ["subscriber-a", "subscriber-b"], stream.subscriber_ids.sort
    assert_equal "public", stream.identity_signature
    assert_includes stream.html, "Plan v2"
    assert_equal stream.to_html, batch.envelope_for("subscriber-a").body
    assert_equal stream.to_html, batch.envelope_for("subscriber-b").body
  end

  def test_public_fragment_payload_reports_one_render_when_bytes_match
    card = create_delivery_card!("Plan")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")
    register_controller_subscription(store, subscriber_id: "subscriber-b")

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    events = []
    subscriber = ActiveSupport::Notifications.subscribe("build_turbo_streams.upkeep") { |event| events << event }

    delivery.build(plan_for(store))

    assert_equal 1, events.first.payload.fetch(:renders)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_collection_create_appends_to_upkeep_collection_container
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Review")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "append", turbo_stream["action"]
    assert_equal stream.target_selector, turbo_stream["targets"]
    assert_match(/\A\[data-upkeep-render-site="/, stream.target_selector)
    assert_includes stream.html, "Review"
    refute_includes stream.html, "Plan"
    refute_includes stream.html, "Build"
  end

  def test_public_collection_create_uses_shared_delivery_stream
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")
    register_controller_subscription(store, subscriber_id: "subscriber-b")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Review")

    batch = delivery.build(plan_for(store))

    assert_equal ["subscriber-a", "subscriber-b"], batch.streams.first.subscriber_ids.sort
    assert_equal 1, batch.envelopes.size
    assert_match(/\Ashared:upkeep:shared:/, batch.envelopes.first.subscriber_id)
    assert_match(/\Aupkeep:shared:/, batch.envelopes.first.stream_name)
    assert_includes batch.envelopes.first.body, "Review"
  end

  def test_public_collection_create_uses_direct_delivery_stream_for_single_subscriber
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Review")

    plan = plan_for(store)
    batch = delivery.build(plan)

    assert_nil plan.targets.first.sharing_signature
    assert_nil batch.streams.first.shared_stream_name
    assert_equal ["subscriber-a"], batch.envelopes.map(&:subscriber_id)
    assert_nil batch.envelopes.first.stream_name
    assert_includes batch.envelopes.first.body, "Review"
  end

  def test_building_turbo_streams_emits_cost_notification
    create_delivery_card!("Plan")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Review")

    events = []
    subscription = ActiveSupport::Notifications.subscribe("build_turbo_streams.upkeep") { |event| events << event }

    batch = delivery.build(plan_for(store))
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription

    event = events.first
    assert event
    assert_equal 1, event.payload.fetch(:plans)
    assert_equal 1, event.payload.fetch(:planned_targets)
    assert_equal batch.streams.size, event.payload.fetch(:streams)
    assert_equal batch.envelopes.size, event.payload.fetch(:envelopes)
    assert_equal({ "append" => 1 }, event.payload.fetch(:actions))
    assert_equal({}, event.payload.fetch(:deoptimizations))
    assert_equal 1, event.payload.fetch(:renders)
    assert_operator event.payload.fetch(:render_duration_ms), :>=, 0.0
    assert_operator event.payload.fetch(:payload_bytes), :>, 0
  end

  def test_public_collection_create_renders_once_for_shared_delivery_stream
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")
    register_controller_subscription(store, subscriber_id: "subscriber-b")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Review")

    render_events = []
    subscriber = ActiveSupport::Notifications.subscribe("render_partial.action_view") do |event|
      render_events << event if event.payload[:identifier].to_s.end_with?("delivery_cards/_card.html.erb")
    end

    delivery.build(plan_for(store))

    assert_equal 1, render_events.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_queued_collection_create_appends_when_later_rows_already_exist
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    review = create_delivery_card!("Review")
    create_delivery_card!("Ship")

    first_create = Upkeep::Runtime::ChangeLog.events.find { |event| event.fetch(:id) == review.id }
    batch = delivery.build(Upkeep::Invalidation::Planner.new(store: store).plan([first_create]))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "append", turbo_stream["action"]
    assert_includes stream.html, "Review"
    refute_includes stream.html, "Plan"
    refute_includes stream.html, "Build"
    refute_includes stream.html, "Ship"
  end

  def test_collection_create_prepends_when_record_belongs_first
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a", path: "/cards?status=open&order=title_desc")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Zed")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "prepend", turbo_stream["action"]
    assert_equal stream.target_selector, turbo_stream["targets"]
    assert_includes stream.html, "Zed"
    refute_includes stream.html, "Plan"
    refute_includes stream.html, "Build"
  end

  def test_collection_create_prepends_for_unfilled_limited_relation
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a", path: "/cards?status=open&order=title_desc&limit=50")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Zed")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "prepend", turbo_stream["action"]
    assert_nil stream.deoptimization_reason
    assert_includes stream.html, "Zed"
    refute_includes stream.html, "Plan"
    refute_includes stream.html, "Build"
  end

  def test_collection_destroy_removes_rendered_member
    card = create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    card.destroy!

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "remove", turbo_stream["action"]
    assert_equal "#delivery_card_#{card.id}", turbo_stream["targets"]
    assert_empty turbo_stream.css("template")
    assert_empty stream.html
  end

  def test_public_collection_member_remove_uses_subscription_shared_stream
    card = create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")
    register_controller_subscription(store, subscriber_id: "subscriber-b")

    subscription_shared_streams = store.subscriptions.flat_map do |subscription|
      Upkeep::SharedStreams.names_for_subscription(subscription)
    end.uniq
    refute_empty subscription_shared_streams

    Upkeep::Runtime::ChangeLog.reset
    card.destroy!

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first

    assert_equal "remove", stream.action
    assert_equal ["subscriber-a", "subscriber-b"], stream.subscriber_ids.sort
    refute_nil stream.shared_stream_name
    assert_includes subscription_shared_streams, stream.shared_stream_name
    assert_equal 1, batch.envelopes.size
    assert_equal stream.shared_stream_name, batch.envelopes.first.stream_name
  end

  def test_collection_update_replaces_existing_member_when_order_is_stable
    create_delivery_card!("Alpha")
    card = create_delivery_card!("Mango")
    create_delivery_card!("Zulu")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a", path: "/cards?status=open&order=title")

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Nectarine")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "replace", turbo_stream["action"]
    assert_equal "morph", turbo_stream["method"]
    assert_nil stream.deoptimization_reason
    assert_equal "#delivery_card_#{card.id}", turbo_stream["targets"]
    assert_includes stream.html, "Nectarine"
    refute_includes stream.html, "Alpha"
    refute_includes stream.html, "Zulu"
  end

  def test_collection_update_falls_back_to_render_site_when_member_order_changes
    create_delivery_card!("Alpha")
    card = create_delivery_card!("Mango")
    create_delivery_card!("Zulu")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a", path: "/cards?status=open&order=title")

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Aardvark")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "update", turbo_stream["action"]
    assert_equal "morph", turbo_stream["method"]
    assert_equal "collection_member_replace_unproven", stream.deoptimization_reason
    assert_match(/\A\[data-upkeep-render-site="/, turbo_stream["targets"])
    assert_includes stream.html, "Aardvark"
    assert_includes stream.html, "Alpha"
    assert_includes stream.html, "Zulu"
  end

  def test_collection_update_falls_back_to_render_site_when_member_leaves_relation
    create_delivery_card!("Alpha")
    card = create_delivery_card!("Mango")
    create_delivery_card!("Zulu")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a", path: "/cards?status=open&order=title")

    Upkeep::Runtime::ChangeLog.reset
    card.update!(status: "closed")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "update", turbo_stream["action"]
    assert_equal "morph", turbo_stream["method"]
    assert_equal "collection_member_replace_unproven", stream.deoptimization_reason
    assert_match(/\A\[data-upkeep-render-site="/, turbo_stream["targets"])
    assert_includes stream.html, "Alpha"
    refute_includes stream.html, "Mango"
    assert_includes stream.html, "Zulu"
  end

  def test_collection_create_after_member_destroy_updates_render_site_container
    victim = create_delivery_card!("Alpha")
    create_delivery_card!("Mango")
    create_delivery_card!("Zulu")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a", path: "/cards?status=open&order=title")

    Upkeep::Runtime::ChangeLog.reset
    victim.destroy!
    remove_stream = delivery.build(plan_for(store)).streams.first
    assert_equal "remove", remove_stream.action

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Review")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "update", turbo_stream["action"]
    assert_equal "morph", turbo_stream["method"]
    assert_equal "collection_create_position_unproven", stream.deoptimization_reason
    assert_match(/\A\[data-upkeep-render-site="/, turbo_stream["targets"])
    assert_includes stream.html, "Review"
    refute_includes stream.to_html, "<upkeep-render-site"
  end

  def test_scalar_page_dependency_uses_turbo_refresh_instead_of_document_replacement
    card = create_delivery_card!("Plan")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a", path: "/cards/titles?status=open", action: :titles)

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    batch = delivery.build(plan_for(store))
    stream = batch.streams.first
    turbo_stream = Nokogiri::HTML5.fragment(stream.to_html).at_css("turbo-stream")

    assert_equal "refresh", turbo_stream["action"]
    assert_equal "morph", turbo_stream["method"]
    assert_equal "preserve", turbo_stream["scroll"]
    refute turbo_stream["targets"]
    assert_empty stream.html
  end

  def test_collection_create_skips_delivery_when_created_record_does_not_match_relation
    create_delivery_card!("Plan")
    create_delivery_card!("Build")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    create_delivery_card!("Archived", status: "closed")

    batch = delivery.build(plan_for(store))

    assert_empty batch.streams
  end

  def test_render_failure_for_one_target_is_isolated_and_other_targets_still_deliver
    card = create_delivery_card!("Plan")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    plan = plan_for(store)
    healthy_target = plan.targets.first
    refute_nil healthy_target

    failing_target = raising_planned_target
    augmented_plan = Upkeep::Invalidation::Planner::Plan.new(
      plan.targets + [failing_target],
      plan.candidate_entries,
      plan.matched_entries
    )

    events = []
    subscriber = ActiveSupport::Notifications.subscribe("delivery_error.upkeep") { |event| events << event }

    batch = nil
    batch = delivery.build_many([augmented_plan]) # must not raise

    assert_equal 1, batch.streams.size
    assert_includes batch.streams.first.html, "Plan v2"

    assert_equal 1, events.size
    payload = events.first.payload
    assert_equal "boom", payload.fetch(:error_message)
    assert_equal "RuntimeError", payload.fetch(:error_class)
    assert_equal "replace", payload.fetch(:action)
    assert_equal ["subscriber-z"], payload.fetch(:subscriber_ids)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_identity_partitioned_payloads_are_not_cross_delivered
    reset_domain_database
    store = Upkeep::Subscriptions::Store.new
    render_identity_subscription(store, subscriber_id: "Alice", user_name: "Alice")
    render_identity_subscription(store, subscriber_id: "Bob", user_name: "Bob")

    Upkeep::Runtime::ChangeLog.reset
    Upkeep::Domain::Card.find_by!(title: "Plan").update!(value: 90)

    batch = delivery.build(plan_for(store))

    assert_equal 2, batch.streams.size
    assert_equal 2, batch.streams.map(&:identity_signature).uniq.size
    assert_equal 2, batch.streams.map(&:html_digest).uniq.size

    alice_body = batch.envelope_for("Alice").body
    bob_body = batch.envelope_for("Bob").body

    assert_includes alice_body, "$90"
    assert_includes bob_body, "Hidden"
    refute_includes bob_body, "$90"
  end

  def test_delivery_report_exposes_target_identity_dependencies_and_payload_digest
    card = create_delivery_card!("Plan")

    store = Upkeep::Subscriptions::Store.new
    register_controller_subscription(store, subscriber_id: "subscriber-a")

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    report = delivery.build(plan_for(store)).report
    stream_report = report.fetch(:streams).first

    assert_equal "replace", stream_report.fetch(:action)
    assert_nil stream_report.fetch(:deoptimization_reason)
    assert_equal "fragment", stream_report.fetch(:target).fetch(:kind)
    assert_equal "public", stream_report.fetch(:identity_signature)
    assert_equal 64, stream_report.fetch(:html_digest).length
    assert_operator stream_report.fetch(:render_duration_ms), :>=, 0.0
    assert_equal ["subscriber-a"], stream_report.fetch(:subscriber_ids)
    assert_nil stream_report[:shared_stream_name]
    assert_operator stream_report.fetch(:matched_dependency_keys).size, :>, 0
    assert_equal ["subscriber-a"], report.fetch(:envelopes).map { |envelope| envelope.fetch(:subscriber_id) }
  end

  private

  def delivery
    Upkeep::Delivery::TurboStreams.new
  end

  def plan_for(store)
    Upkeep::Invalidation::Planner.new(store: store).plan(Upkeep::Runtime::ChangeLog.events)
  end

  def raising_planned_target
    recipe = Upkeep::Replay::Recipe.new(
      kind: :fragment,
      frame_id: "fragment:rails:delivery_cards/_card:boom",
      target_kind: "fragment",
      target_id: "fragment:rails:delivery_cards/_card:boom"
    ) { raise "boom" }

    target = Upkeep::Targeting::Target.new("fragment", "fragment:rails:delivery_cards/_card:boom", "boom")

    Upkeep::Invalidation::Planner::PlannedTarget.new(
      "subscription-z",
      "subscriber-z",
      ["subscriber-z"],
      target,
      target,
      "fragment:rails:delivery_cards/_card:boom",
      "public",
      nil,
      recipe,
      ["boom"],
      "replace",
      nil
    )
  end

  def create_delivery_card!(title, status: "open")
    DeliveryCard.create!(title: title, status: status)
  end

  def register_controller_subscription(store, subscriber_id:, path: "/cards?status=open", action: :index)
    _html, recorder = capture_controller_request(path, action: action)
    subscription = store.register(subscriber_id: subscriber_id, recorder: recorder)
    store.activate(subscription.id)
    subscription
  end

  def capture_controller_request(path, action: :index)
    result, recorder = Upkeep::Runtime::Observation.capture_request do
      _status, _headers, body = DeliveryCardsController.action(action).call(Rack::MockRequest.env_for(path))
      [collect_body(body), Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def render_identity_subscription(store, subscriber_id:, user_name:)
    user = Upkeep::Domain::User.find_by!(name: user_name)
    result = renderer.render_request("boards/identity_collection", method(:domain_request), user: user)
    subscription = store.register(subscriber_id: subscriber_id, recorder: result.recorder)
    store.activate(subscription.id)
    subscription
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
      "delivery_cards/index.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "delivery_cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "delivery_cards/titles.html.erb" => <<~ERB,
        <main>
          <p><%= @titles.join(", ") %></p>
        </main>
      ERB
      "delivery_cards/_card.html.erb" => <<~ERB
        <li id="delivery_card_<%= card.id %>">
          <span class="title"><%= card.title %></span>
          <span class="status"><%= card.status %></span>
        </li>
      ERB
    )
  end
end
