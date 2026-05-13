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
    @cards = params[:order] == "title_desc" ? cards.order(title: :desc) : cards.order(:id)
    render template: "delivery_cards/index"
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

  def test_collection_create_appends_to_upkeep_collection_wrapper
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
    assert_match(/\Aupkeep-render-site\[data-upkeep-render-site="/, stream.target_selector)
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

    assert_equal 1, batch.envelopes.size
    assert_match(/\Ashared:upkeep:shared:/, batch.envelopes.first.subscriber_id)
    assert_match(/\Aupkeep:shared:/, batch.envelopes.first.stream_name)
    assert_includes batch.envelopes.first.body, "Review"
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
    assert_equal "fragment", stream_report.fetch(:target).fetch(:kind)
    assert_equal "public", stream_report.fetch(:identity_signature)
    assert_equal 64, stream_report.fetch(:html_digest).length
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

  def create_delivery_card!(title, status: "open")
    DeliveryCard.create!(title: title, status: status)
  end

  def register_controller_subscription(store, subscriber_id:, path: "/cards?status=open")
    _html, recorder = capture_controller_request(path)
    store.register(subscriber_id: subscriber_id, recorder: recorder)
  end

  def capture_controller_request(path)
    result, recorder = Upkeep::Runtime::Observation.capture_request do
      _status, _headers, body = DeliveryCardsController.action(:index).call(Rack::MockRequest.env_for(path))
      [collect_body(body), Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def render_identity_subscription(store, subscriber_id:, user_name:)
    user = Upkeep::Domain::User.find_by!(name: user_name)
    result = renderer.render_request("boards/identity_collection", method(:domain_request), user: user)
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
      "delivery_cards/index.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "delivery_cards/card", collection: @cards, as: :card %>
          </ul>
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
