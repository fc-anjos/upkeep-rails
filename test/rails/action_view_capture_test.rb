# frozen_string_literal: true

require "json"
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

  def materialized_index
    @cards = RailsCaptureCard.where(status: params.fetch(:status)).order(:id).to_a
    render template: "controller_cards/index"
  end

  def hidden_lookup_index
    RailsCaptureCard.where(status: "closed").order(:id).to_a
    @cards = RailsCaptureCard.where(status: "open").order(:id)
    render template: "controller_cards/index"
  end

  def show
    @card = RailsCaptureCard.find(params.fetch(:id))
    render template: "controller_cards/show"
  end

  def session_index
    @viewer = session[:viewer]
    @cards = RailsCaptureCard.order(:id)
    render template: "controller_cards/session_index"
  end

  def cookie_index
    @viewer = cookies[:viewer]
    @cards = RailsCaptureCard.order(:id)
    render template: "controller_cards/session_index"
  end

  def request_index
    @viewer = request.user_agent
    @cards = RailsCaptureCard.order(:id)
    render template: "controller_cards/session_index"
  end

  def session_members
    @cards = RailsCaptureCard.order(:id)
    render template: "controller_cards/session_members"
  end
end

class ActionViewCaptureTest < Minitest::Test
  class TestRackSession < ActiveSupport::HashWithIndifferentAccess
    def enabled? = true

    def loaded? = true

    def id = to_hash["session_id"]

    def [](key)
      value = super
      Upkeep::Runtime::Ambient.record_session(key, value)
      value
    end

    def fetch(key, *args, &block)
      value = super
      Upkeep::Runtime::Ambient.record_session(key, value)
      value
    end
  end

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

    html, recorder = capture_render("boards/mixed", {
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
    assert_equal 4, recorder.graph.summary.fetch(:manifest_attached_frames)
    assert_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_attribute"
    assert_includes html, 'data-upkeep-page-frame="page:rails:boards/mixed"'
    assert_includes html, %(data-upkeep-frame="fragment:rails:cards/_card:rails_capture_cards:#{explicit.id}")
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

  def test_controller_page_recipe_preserves_rack_session
    create_card!("Plan")

    html, recorder = capture_controller_request(
      :session_index,
      "/cards/session",
      session: {
        viewer: "Alice",
        oauth_state: "unread-secret",
        totp_secret: "also-unread"
      }
    )

    assert_includes html, "Alice"

    page_frame = recorder.graph.node("page:rails:controller_cards/session_index")
    recipe_snapshot = page_frame.payload.fetch(:recipe).to_h
    recipe = Upkeep::Replay::Recipe.from_h(recipe_snapshot)
    replayed_html = recipe.render
    session_snapshot = recipe_snapshot.fetch(:replay).fetch(:env).fetch("rack.session")

    assert_includes replayed_html, "Alice"
    assert_includes replayed_html, "Plan"
    assert_equal "rack_session", session_snapshot.fetch("__upkeep_replay_type")
    assert_equal({ "viewer" => "Alice" }, session_snapshot.fetch("values"))
  end

  def test_unread_rack_session_values_do_not_change_page_replay_env
    create_card!("Plan")

    _html, first_recorder = capture_controller_request(
      :session_index,
      "/cards/session",
      session: { viewer: "Alice", oauth_state: "first" }
    )
    _html, second_recorder = capture_controller_request(
      :session_index,
      "/cards/session",
      session: { viewer: "Alice", oauth_state: "second" }
    )

    first_env = controller_page_recipe_env(first_recorder, "page:rails:controller_cards/session_index")
    second_env = controller_page_recipe_env(second_recorder, "page:rails:controller_cards/session_index")

    assert_equal first_env.fetch("rack.session"), second_env.fetch("rack.session")
    assert_equal Upkeep::SharedStreams.names_for_recorder(first_recorder), Upkeep::SharedStreams.names_for_recorder(second_recorder)
    refute_includes first_env.fetch("rack.session").fetch("values"), "oauth_state"
  end

  def test_controller_page_recipe_excludes_unread_security_session_values
    create_card!("Plan")
    secrets = {
      oauth_state: "oauth-secret-value",
      totp_secret: "totp-secret-value",
      csrf_token: "csrf-secret-value",
      redirect_state: "redirect-secret-value"
    }

    _html, recorder = capture_controller_request(
      :session_index,
      "/cards/session",
      session: secrets.merge(viewer: "Alice")
    )

    recipe_snapshot = recorder.graph.node("page:rails:controller_cards/session_index").payload.fetch(:recipe).to_h
    recipe_json = JSON.generate(recipe_snapshot)
    session_values = recipe_snapshot.fetch(:replay).fetch(:env).fetch("rack.session").fetch("values")

    assert_includes recipe_json, "Alice"
    assert_operator JSON.generate(recipe_snapshot.fetch(:replay)).bytesize, :<, 2_500
    secrets.each_value { |secret| refute_includes recipe_json, secret }
    secrets.each_key { |key| refute_includes session_values, key.to_s }
  end

  def test_graph_report_redacts_replay_values
    create_card!("Plan")

    _html, recorder = capture_controller_request(
      :session_index,
      "/cards/session",
      session: { viewer: "Alice", oauth_state: "oauth-secret-value" }
    )

    report_json = JSON.generate(recorder.graph.report)

    assert_includes report_json, "viewer"
    assert_includes report_json, "String"
    assert_includes report_json, "digest"
    assert_includes report_json, "bytes"
    refute_includes report_json, "Alice"
    refute_includes report_json, "oauth-secret-value"
  end

  def test_page_identity_inherits_request_ambient_reads_without_poisoning_render_site_sharing
    create_card!("Plan")

    _html, recorder = capture_controller_request(
      :session_index,
      "/cards/session",
      session: { viewer: "Alice" }
    )

    render_site = recorder.graph.frame_nodes.find { |frame| frame.payload.fetch(:kind) == "render_site" }

    assert render_site
    assert_includes recorder.identity_profile("page:rails:controller_cards/session_index").map { |dependency| dependency.fetch(:source).to_s }, "session"
    refute_equal "public", recorder.identity_signature("page:rails:controller_cards/session_index")
    assert_equal "public", recorder.identity_signature(render_site.id)
    assert_equal ["upkeep:shared:"], Upkeep::SharedStreams.names_for_recorder(recorder).map { |name| name[0, 14] }.uniq
  end

  def test_controller_page_recipe_preserves_observed_cookies_only
    create_card!("Plan")

    html, recorder = capture_controller_request(
      :cookie_index,
      "/cards/cookie",
      cookies: {
        viewer: "Alice",
        oauth_state: "unread-secret"
      }
    )

    assert_includes html, "Alice"

    page_frame = recorder.graph.node("page:rails:controller_cards/session_index")
    recipe_snapshot = page_frame.payload.fetch(:recipe).to_h
    recipe = Upkeep::Replay::Recipe.from_h(recipe_snapshot)
    replayed_html = recipe.render
    cookie_header = recipe_snapshot.fetch(:replay).fetch(:env).fetch("HTTP_COOKIE")

    assert_includes replayed_html, "Alice"
    assert_includes cookie_header, "viewer=Alice"
    refute_includes cookie_header, "oauth_state"
  end

  def test_controller_page_recipe_excludes_unread_security_cookie_values
    create_card!("Plan")
    secrets = {
      oauth_state: "oauth-cookie-secret",
      csrf_token: "csrf-cookie-secret",
      redirect_state: "redirect-cookie-secret"
    }

    _html, recorder = capture_controller_request(
      :cookie_index,
      "/cards/cookie",
      cookies: secrets.merge(viewer: "Alice")
    )

    recipe_snapshot = recorder.graph.node("page:rails:controller_cards/session_index").payload.fetch(:recipe).to_h
    recipe_json = JSON.generate(recipe_snapshot)
    cookie_header = recipe_snapshot.fetch(:replay).fetch(:env).fetch("HTTP_COOKIE")

    assert_includes cookie_header, "viewer=Alice"
    assert_operator JSON.generate(recipe_snapshot.fetch(:replay)).bytesize, :<, 2_500
    secrets.each_value { |secret| refute_includes recipe_json, secret }
    secrets.each_key { |key| refute_includes cookie_header, key.to_s }
  end

  def test_controller_page_recipe_replays_observed_request_headers_only
    create_card!("Plan")

    html, recorder = capture_controller_request(
      :request_index,
      "/cards/request",
      env: {
        "HTTP_USER_AGENT" => "UpkeepBrowser",
        "HTTP_AUTHORIZATION" => "Bearer request-secret",
        "HTTP_X_CSRF_TOKEN" => "csrf-request-secret"
      }
    )

    assert_includes html, "UpkeepBrowser"

    recipe_snapshot = recorder.graph.node("page:rails:controller_cards/session_index").payload.fetch(:recipe).to_h
    recipe = Upkeep::Replay::Recipe.from_h(recipe_snapshot)
    replayed_html = recipe.render
    replay_env = recipe_snapshot.fetch(:replay).fetch(:env)
    recipe_json = JSON.generate(recipe_snapshot)

    assert_includes replayed_html, "UpkeepBrowser"
    assert_equal "UpkeepBrowser", replay_env.fetch("HTTP_USER_AGENT")
    assert_operator JSON.generate(recipe_snapshot.fetch(:replay)).bytesize, :<, 2_500
    refute_includes replay_env, "HTTP_AUTHORIZATION"
    refute_includes replay_env, "HTTP_X_CSRF_TOKEN"
    refute_includes recipe_json, "request-secret"
    refute_includes recipe_json, "csrf-request-secret"
  end

  def test_render_site_identity_includes_descendant_ambient_reads
    create_card!("Plan")

    _html, recorder = capture_controller_request(
      :session_members,
      "/cards/session-members",
      session: { viewer: "Alice" }
    )

    render_site = recorder.graph.frame_nodes.find { |frame| frame.payload.fetch(:kind) == "render_site" }

    assert render_site
    assert_includes recorder.identity_profile(render_site.id).map { |dependency| dependency.fetch(:source).to_s }, "session"
    refute_equal "public", recorder.identity_signature(render_site.id)
    assert_empty Upkeep::SharedStreams.names_for_recorder(recorder)
  end


  def test_collection_render_records_render_site_and_replays_membership_change
    plan = create_card!("Plan")
    build = create_card!("Build")

    html, recorder = capture_render("boards/collection", cards: RailsCaptureCard.order(:id))

    Upkeep::Runtime::ChangeLog.reset
    create_card!("Review")

    targets = Upkeep::Targeting::Selector.new.select(recorder, Upkeep::Runtime::ChangeLog.events)
    recipe = recorder.graph.node(Upkeep::Targeting::Extraction.frame_id_for(targets.first)).payload.fetch(:recipe)
    replayed_html = recipe.render
    collection_snapshot = recipe.replay.collection

    assert_equal ["render_site"], targets.map(&:kind).uniq
    assert_includes replayed_html, "Review"
    assert_equal [plan.id.to_s, build.id.to_s], collection_snapshot.member_ids
    assert_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_collection"

    render_site = recorder.graph.frame_nodes.find { |frame| frame.payload.fetch(:kind) == "render_site" }
    page = recorder.graph.node("page:rails:boards/collection")
    fragment = recorder.graph.node("fragment:rails:cards/_card:rails_capture_cards:#{plan.id}")

    assert_equal "boards/collection", page.payload.fetch(:manifest_path)
    assert_equal "boards/collection", render_site.payload.fetch(:manifest_path)
    assert_equal "cards/_card", fragment.payload.fetch(:manifest_path)
    assert_equal render_site.payload.fetch(:manifest_path), recipe.manifest_reference.fetch(:path)
    assert_includes html, %(upkeep-render-site data-upkeep-render-site="#{render_site.payload.fetch(:site_id)}")
    assert_includes html, %(data-upkeep-frame="fragment:rails:cards/_card:rails_capture_cards:#{plan.id}")
  end

  def test_controller_materialized_relation_records_render_site_collection_dependency
    plan = create_card!("Plan", status: "open")
    build = create_card!("Build", status: "open")
    create_card!("Archived", status: "closed")

    html, recorder = capture_controller_request(:materialized_index, "/cards/materialized?status=open")

    assert_includes html, "Plan"
    refute_includes html, "Archived"

    Upkeep::Runtime::ChangeLog.reset
    create_card!("Review", status: "open")

    targets = Upkeep::Targeting::Selector.new.select(recorder, Upkeep::Runtime::ChangeLog.events)
    recipe = recorder.graph.node(Upkeep::Targeting::Extraction.frame_id_for(targets.first)).payload.fetch(:recipe)
    replayed_html = recipe.render
    collection_snapshot = recipe.replay.collection
    render_site = recorder.graph.frame_nodes.find { |frame| frame.payload.fetch(:kind) == "render_site" }
    render_site_dependencies = recorder.graph.dependencies_for(render_site.id).map(&:source)
    request_dependencies = recorder.graph.dependencies_for(Upkeep::Runtime::Recorder::REQUEST_NODE_ID).map(&:source)

    assert_equal ["render_site"], targets.map(&:kind).uniq
    assert_includes replayed_html, "Review"
    assert_equal "active_record_relation", collection_snapshot.type
    assert_equal [plan.id.to_s, build.id.to_s], collection_snapshot.member_ids
    assert_includes render_site_dependencies, :active_record_collection
    refute_includes request_dependencies, :active_record_collection
  end

  def test_unrendered_controller_relation_does_not_create_collection_dependency
    create_card!("Plan", status: "open")
    create_card!("Archived", status: "closed")

    html, recorder = capture_controller_request(:hidden_lookup_index, "/cards/hidden")
    request_dependencies = recorder.graph.dependencies_for(Upkeep::Runtime::Recorder::REQUEST_NODE_ID).map(&:source)

    assert_includes html, "Plan"
    refute_includes html, "Archived"
    refute_includes request_dependencies, :active_record_collection

    Upkeep::Runtime::ChangeLog.reset
    create_card!("Still archived", status: "closed")

    targets = Upkeep::Targeting::Selector.new.select(recorder, Upkeep::Runtime::ChangeLog.events)

    assert_empty targets
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

  def test_opaque_predicate_collection_relation_raises_before_materialization
    select_sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      select_sql << sql if sql.start_with?("SELECT") && sql.include?('"rails_capture_cards"')
    end

    relation = RailsCaptureCard.where("status = ?", "open")

    error = assert_raises(Upkeep::ActiveRecordQuery::OpaqueRelationError) do
      capture_render("boards/collection", cards: relation)
    end

    assert_includes error.message, "cannot make this Active Record relation reactive"
    assert_includes error.message, "raw SQL predicate"
    assert_empty select_sql
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def test_warn_policy_refuses_opaque_collection_without_broad_dependency
    previous_behavior = Upkeep::Rails.configuration.refused_boundary_behavior
    Upkeep::Rails.configuration.refused_boundary_behavior = :warn
    create_card!("Plan")
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("refused_boundary.upkeep") do |_name, _started, _finished, _id, payload|
      events << payload
    end

    html, recorder = capture_render("boards/collection", cards: RailsCaptureCard.where("status = ?", "open"))

    assert_includes html, "Plan"
    refute recorder.reactive?
    assert_equal 1, recorder.refused_boundaries.size
    assert_equal "opaque_active_record_relation", recorder.refused_boundaries.first.reason
    assert_includes events.map { |event| event.fetch(:reason) }, "opaque_active_record_relation"
    refute_includes recorder.graph.summary.fetch(:dependency_sources), "active_record_collection"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    Upkeep::Rails.configuration.refused_boundary_behavior = previous_behavior if previous_behavior
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

  def capture_controller_request(action_or_path, path = nil, path_parameters: {}, session: nil, cookies: nil, env: {})
    action = path ? action_or_path : :index
    path ||= action_or_path

    result, recorder = Upkeep::Runtime::Observation.capture_request do
      request_env = Rack::MockRequest.env_for(path).merge(env)
      request_env["action_dispatch.request.path_parameters"] = path_parameters if path_parameters.any?
      request_env["rack.session"] = TestRackSession.new(session) if session
      request_env["HTTP_COOKIE"] = cookie_header(cookies) if cookies
      _status, _headers, body = RailsCaptureCardsController.action(action).call(request_env)
      [collect_body(body), Upkeep::Runtime::Observation.recorder]
    end

    result || [nil, recorder]
  end

  def cookie_header(cookies)
    cookies.map { |key, value| "#{CGI.escape(key.to_s)}=#{CGI.escape(value.to_s)}" }.join("; ")
  end

  def controller_page_recipe_env(recorder, frame_id)
    recorder.graph.node(frame_id).payload.fetch(:recipe).to_h.fetch(:replay).fetch(:env)
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
      "controller_cards/session_index.html.erb" => <<~ERB,
        <main>
          <p><%= @viewer %></p>
          <ul>
            <%= render partial: "cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "controller_cards/session_members.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "cards/session_card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "cards/_card.html.erb" => <<~ERB,
        <li id="card_<%= card.id %>">
          <span class="title"><%= card.title %></span>
          <span class="status"><%= card.status %></span>
        </li>
      ERB
      "cards/_session_card.html.erb" => <<~ERB
        <li id="card_<%= card.id %>">
          <span class="viewer"><%= session[:viewer] %></span>
          <span class="title"><%= card.title %></span>
        </li>
      ERB
    )
  end
end
