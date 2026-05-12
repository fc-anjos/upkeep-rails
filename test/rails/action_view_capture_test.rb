# frozen_string_literal: true

require "test_helper"

class RailsCaptureCard < ActiveRecord::Base
  self.table_name = "rails_capture_cards"

  def to_partial_path
    "cards/card"
  end
end

class RailsCaptureCardsController < ActionController::Base
  def index
    @cards = RailsCaptureCard.where(status: params.fetch(:status)).order(:id)
    render template: "controller_cards/index"
  end

  def show
    @card = RailsCaptureCard.find(params.fetch(:id))
    render template: "controller_cards/show"
  end
end

class ActionViewCaptureTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call
    RailsCaptureCardsController.view_paths = [resolver]

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :rails_capture_cards, force: true do |table|
        table.string :title, null: false
        table.string :status, null: false
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def test_rails_resolved_render_shapes_create_frame_graph
    explicit = create_card!("Explicit")
    shorthand = create_card!("Shorthand")
    object = create_card!("Object")

    _html, recorder = capture_render("boards/mixed", {
      explicit_card: explicit,
      shorthand_card: shorthand,
      object_card: object
    })

    frame_report = recorder.graph.report.fetch(:frames)
    fragment_ids = frame_report.filter_map { |frame| frame.fetch(:id) if frame.fetch(:kind) == "fragment" }

    assert_includes fragment_ids, "fragment:rails:cards/_card:rails_capture_cards:#{explicit.id}"
    assert_includes fragment_ids, "fragment:rails:cards/_card:rails_capture_cards:#{shorthand.id}"
    assert_includes fragment_ids, "fragment:rails:cards/_card:rails_capture_cards:#{object.id}"
    assert_equal 4, recorder.graph.summary.fetch(:replay_recipes)
    assert_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_attribute"
  end

  def test_page_recipe_rerenders_with_fresh_relation
    create_card!("Plan")
    create_card!("Build")

    _html, recorder = capture_render("boards/collection", cards: RailsCaptureCard.order(:id))

    create_card!("Review")

    recipe = recorder.graph.node("page:rails:boards/collection").payload.fetch(:recipe)
    replayed_html = recipe.render

    assert_includes replayed_html, "Plan"
    assert_includes replayed_html, "Build"
    assert_includes replayed_html, "Review"
  end

  def test_controller_page_recipe_reruns_action_with_request_parameters
    create_card!("Plan", status: "open")
    create_card!("Archived", status: "closed")

    html, recorder = capture_controller_request("/cards?status=open")

    assert_includes html, "Plan"
    refute_includes html, "Archived"

    create_card!("Review", status: "open")
    create_card!("Done", status: "closed")

    page_frame = recorder.graph.node("page:rails:controller_cards/index")
    replayed_html = page_frame.payload.fetch(:recipe).render

    assert_includes replayed_html, "Plan"
    assert_includes replayed_html, "Review"
    refute_includes replayed_html, "Archived"
    refute_includes replayed_html, "Done"
    assert_equal({
      class: "RailsCaptureCardsController",
      action: "index",
      request_method: "GET",
      path: "/cards",
      query_string_digest: Digest::SHA256.hexdigest("status=open")[0, 16],
      path_parameters: []
    }, page_frame.payload.fetch(:controller))
  end

  def test_controller_page_recipe_reruns_action_with_path_parameters
    card = create_card!("Plan")

    html, recorder = capture_controller_request(:show, "/cards/#{card.id}", path_parameters: { id: card.id })

    assert_includes html, "Plan"

    card.update!(title: "Plan v2")

    page_frame = recorder.graph.node("page:rails:controller_cards/show")
    replayed_html = page_frame.payload.fetch(:recipe).render

    assert_includes replayed_html, "Plan v2"
    refute_includes replayed_html, ">Plan<"
    assert_equal ["id"], page_frame.payload.fetch(:controller).fetch(:path_parameters)
  end


  def test_collection_render_records_render_site_and_replays_membership_change
    plan = create_card!("Plan")
    build = create_card!("Build")

    _html, recorder = capture_render("boards/collection", cards: RailsCaptureCard.order(:id))

    Upkeep::Runtime::ChangeLog.reset
    create_card!("Review")

    targets = Upkeep::Targeting::Selector.new.select(recorder, Upkeep::Runtime::ChangeLog.events)
    recipe = recorder.graph.node(Upkeep::Targeting::Extraction.frame_id_for(targets.first)).payload.fetch(:recipe)
    replayed_html = recipe.render
    collection_snapshot = recipe.replay.fetch(:collection)

    assert_equal ["render_site"], targets.map(&:kind).uniq
    assert_includes replayed_html, "Review"
    assert_equal [plan.id.to_s, build.id.to_s], collection_snapshot.fetch(:member_ids)
    assert_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_collection"
  end

  def test_collection_snapshot_uses_the_rendered_relation_records
    create_card!("Plan")
    create_card!("Build")

    select_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      select_sql << sql if sql.start_with?("SELECT") && sql.include?('"rails_capture_cards"')
    end

    capture_render("boards/collection", cards: RailsCaptureCard.order(:id))

    assert_equal 1, select_sql.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_opaque_collection_relation_raises_before_materialization
    select_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      select_sql << sql if sql.start_with?("SELECT") && sql.include?('"rails_capture_cards"')
    end

    relation = RailsCaptureCard
      .joins("INNER JOIN hidden_cards ON hidden_cards.card_id = rails_capture_cards.id")
      .where(status: "open")

    error = assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) do
      capture_render("boards/collection", cards: relation)
    end

    assert_includes error.message, "cannot make this Active Record relation reactive"
    assert_includes error.message, "raw SQL join"
    assert_empty select_sql
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_record_attribute_change_walks_dependency_to_fragment_and_replays_record
    card = create_card!("Plan")

    _html, recorder = capture_render("boards/collection", cards: RailsCaptureCard.order(:id))

    Upkeep::Runtime::ChangeLog.reset
    card.update!(title: "Plan v2")

    targets = Upkeep::Targeting::Selector.new.select(recorder, Upkeep::Runtime::ChangeLog.events)
    recipe = recorder.graph.node(targets.first.id).payload.fetch(:recipe)
    replayed_html = recipe.render

    assert_equal [
      ["fragment", "fragment:rails:cards/_card:rails_capture_cards:#{card.id}"]
    ], targets.map { |target| [target.kind, target.id] }
    assert_includes replayed_html, "Plan v2"
    refute_includes replayed_html, ">Plan<"
  end

  private

  def create_card!(title, status: "open")
    RailsCaptureCard.create!(title: title, status: status)
  end

  def capture_render(template, locals)
    result, recorder = Upkeep::Runtime::Observation.capture_request do
      html = view.render(template: template, locals: locals)
      [html, Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def capture_controller_request(action_or_path, path = nil, path_parameters: {})
    action = path ? action_or_path : :index
    path ||= action_or_path

    result, recorder = Upkeep::Runtime::Observation.capture_request do
      env = Rack::MockRequest.env_for(path)
      env["action_dispatch.request.path_parameters"] = path_parameters if path_parameters.any?
      _status, _headers, body = RailsCaptureCardsController.action(action).call(env)
      [collect_body(body), Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def collect_body(body)
    body.each.to_a.join
  ensure
    body.close if body.respond_to?(:close)
  end

  def view
    lookup_context = ActionView::LookupContext.new([resolver])
    ActionView::Base.with_empty_template_cache.new(lookup_context, {}, nil).tap do |view|
      view.prefix_partial_path_with_controller_namespace = false
    end
  end

  def resolver
    ActionView::FixtureResolver.new(
      "boards/mixed.html.erb" => <<~ERB,
        <main>
          <%= render partial: "cards/card", locals: { card: explicit_card } %>
          <%= render "cards/card", card: shorthand_card %>
          <%= render object_card %>
        </main>
      ERB
      "boards/collection.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "cards/card", collection: cards, as: :card %>
          </ul>
        </main>
      ERB
      "controller_cards/index.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "controller_cards/show.html.erb" => <<~ERB,
        <main>
          <%= render partial: "cards/card", locals: { card: @card } %>
        </main>
      ERB
      "cards/_card.html.erb" => <<~ERB
        <li id="card_<%= card.id %>">
          <span class="title"><%= card.title %></span>
          <span class="status"><%= card.status %></span>
        </li>
      ERB
    )
  end
end
