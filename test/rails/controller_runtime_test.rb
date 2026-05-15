# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class RuntimeDeliveryUser < ActiveRecord::Base
  self.table_name = "runtime_delivery_users"
end

class RuntimeDeliveryCard < ActiveRecord::Base
  self.table_name = "runtime_delivery_cards"

  def to_partial_path = "runtime_delivery_cards/card"
end

class RuntimeDeliveryCurrent < ActiveSupport::CurrentAttributes
  attribute :user
end

class RuntimeDeliveryCardsController < ActionController::Base
  def index
    @cards = RuntimeDeliveryCard.order(:id)
    render template: "runtime_delivery_cards/index"
  end

  def raw
    @cards = RuntimeDeliveryCard.where("title IS NOT NULL").order(:id)
    render template: "runtime_delivery_cards/index"
  end

  def update
    RuntimeDeliveryCard.find(params.fetch(:id)).update!(title: params.fetch(:title))
    head :ok
  end

  def raw_probe
    RuntimeDeliveryCard.where("title IS NOT NULL").to_a
    head :ok
  end

  def anonymous
    @cards = RuntimeDeliveryCard.order(:id)
    render template: "runtime_delivery_cards/anonymous"
  end

  def request_variant
    @cards = RuntimeDeliveryCard.order(:id)
    @user_agent = request.user_agent
    render template: "runtime_delivery_cards/request_variant"
  end
end

class ControllerRuntimeTest < Minitest::Test
  class RecordingAdapter
    attr_reader :bodies

    def initialize
      @bodies = []
    end

    def deliver(envelope)
      bodies << envelope.body
    end
  end

  def setup
    Upkeep::Rails.reset_runtime!
    Upkeep::Rails::Install.reset!
    Upkeep::Rails::Install.call
    RuntimeDeliveryCardsController.view_paths = [resolver]

    @database_dir = Dir.mktmpdir("upkeep-controller-runtime")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(@database_dir, "test.sqlite3"))
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :runtime_delivery_users, force: true do |table|
        table.string :name, null: false
      end

      create_table :runtime_delivery_cards, force: true do |table|
        table.string :title, null: false
      end
    end

    Upkeep::Runtime::ChangeLog.reset
  end

  def teardown
    RuntimeDeliveryCurrent.reset
    Upkeep::Rails.reset_runtime!
    FileUtils.rm_rf(@database_dir) if @database_dir
  end

  def test_get_registers_subscription_and_injects_client_marker
    user = RuntimeDeliveryUser.create!(name: "Alice")
    RuntimeDeliveryCard.create!(title: "Plan")
    RuntimeDeliveryCurrent.user = user

    events = capture_notifications(Upkeep::Rails::SUBSCRIPTION_IDENTITY) do
      _status, _headers, body = RuntimeDeliveryCardsController.action(:index).call(env_for("/cards"))
      @html = collect_body(body)
    end
    html = @html
    subscription = Upkeep::Rails.subscriptions.subscriptions.first

    assert subscription
    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::IDENTIFIED_MODE, subscription.metadata.fetch(:identity_mode)
    assert_equal "identity_dependencies_present", subscription.metadata.fetch(:anonymous_deopt_reason)
    assert_includes subscription.metadata.fetch(:identity_sources), "current_attribute"
    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::IDENTIFIED_MODE, events.last.payload.fetch(:identity_mode)
    assert_equal "identity_dependencies_present", events.last.payload.fetch(:anonymous_deopt_reason)
    assert_equal subscription.subscriber_id, Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: user).subscriber_id
    assert_includes html, "data-upkeep-subscription"
    assert_includes html, subscription.id
    assert_includes html, Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: user).stream_name
  end

  def test_anonymous_get_registers_subscription_and_injects_client_marker
    RuntimeDeliveryCard.create!(title: "Plan")

    events = capture_notifications(Upkeep::Rails::SUBSCRIPTION_IDENTITY) do
      _status, _headers, body = RuntimeDeliveryCardsController.action(:anonymous).call(env_for("/cards"))
      @html = collect_body(body)
    end
    html = @html
    subscription = Upkeep::Rails.subscriptions.subscriptions.first

    assert subscription
    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE, subscription.metadata.fetch(:identity_mode)
    assert_equal true, subscription.metadata.fetch(:anonymous)
    assert_nil subscription.metadata[:anonymous_deopt_reason]
    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE, events.last.payload.fetch(:identity_mode)
    assert_equal true, events.last.payload.fetch(:anonymous)
    assert_includes html, "data-upkeep-subscription"
    assert_includes html, subscription.id
    assert_includes html, subscription.metadata.fetch(:stream_name)
  end

  def test_identity_free_get_reuses_subscription_shape_without_reusing_response_html
    RuntimeDeliveryCard.create!(title: "Plan")

    events = capture_notifications(Upkeep::Subscriptions::ShapeCache::NOTIFICATION) do
      _status, _headers, first_body = RuntimeDeliveryCardsController.action(:anonymous).call(env_for("/cards"))
      @first_html = collect_body(first_body)
      _status, _headers, second_body = RuntimeDeliveryCardsController.action(:anonymous).call(env_for("/cards"))
      @second_html = collect_body(second_body)
    end
    subscriptions = Upkeep::Rails.subscriptions.subscriptions

    assert_equal ["miss", "hit"], events.map { |event| event.payload.fetch(:cache_state) }
    assert_equal 2, subscriptions.size
    assert_equal ["hit", "miss"], subscriptions.map { |subscription| subscription.metadata.fetch(:subscription_shape_cache) }.sort
    refute_equal subscriptions.first.id, subscriptions.last.id
    assert_includes @first_html, subscriptions.first.id
    assert_includes @second_html, subscriptions.last.id
  end

  def test_identity_free_get_stays_anonymous_even_when_session_exists
    RuntimeDeliveryCard.create!(title: "Plan")
    env = env_for("/cards")
    env["rack.session"] = { "session_id" => "existing-session" }

    _status, _headers, body = RuntimeDeliveryCardsController.action(:anonymous).call(env)
    collect_body(body)
    subscription = Upkeep::Rails.subscriptions.subscriptions.first

    assert subscription
    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE, subscription.metadata.fetch(:identity_mode)
    refute_includes subscription.subscriber_id, "existing-session"
  end

  def test_request_replay_inputs_do_not_force_connection_identity
    RuntimeDeliveryCard.create!(title: "Plan")

    _status, _headers, body = RuntimeDeliveryCardsController.action(:request_variant).call(
      env_for("/cards/request", params: {}, method: "GET").merge("HTTP_USER_AGENT" => "UpkeepBench")
    )
    collect_body(body)
    subscription = Upkeep::Rails.subscriptions.subscriptions.first

    assert subscription
    assert_equal Upkeep::Rails::Cable::SubscriberIdentity::ANONYMOUS_PUBLIC_MODE, subscription.metadata.fetch(:identity_mode)
    assert_includes subscription.recorder.graph.summary.fetch(:dependency_sources), "request"
  end

  def test_warn_policy_refuses_subscription_registration_for_opaque_collection
    previous_behavior = Upkeep::Rails.configuration.refused_boundary_behavior
    Upkeep::Rails.configuration.refused_boundary_behavior = :warn
    user = RuntimeDeliveryUser.create!(name: "Alice")
    RuntimeDeliveryCard.create!(title: "Plan")
    RuntimeDeliveryCurrent.user = user

    _status, _headers, body = RuntimeDeliveryCardsController.action(:raw).call(env_for("/cards/raw"))
    html = collect_body(body)

    assert_includes html, "Plan"
    assert_empty Upkeep::Rails.subscriptions.subscriptions
    refute_includes html, "data-upkeep-subscription"
  ensure
    Upkeep::Rails.configuration.refused_boundary_behavior = previous_behavior if previous_behavior
  end

  def test_non_get_request_does_not_register_subscription_or_observe_queries
    RuntimeDeliveryCard.create!(title: "Plan")

    _status, _headers, body = RuntimeDeliveryCardsController.action(:raw_probe).call(
      env_for("/cards/raw-probe", method: "POST")
    )
    collect_body(body)

    assert_empty Upkeep::Rails.subscriptions.subscriptions
  end

  def test_mutation_request_delivers_planned_streams_to_connected_subscriber
    user = RuntimeDeliveryUser.create!(name: "Alice")
    card = RuntimeDeliveryCard.create!(title: "Plan")
    RuntimeDeliveryCurrent.user = user

    _status, _headers, body = RuntimeDeliveryCardsController.action(:index).call(env_for("/cards"))
    collect_body(body)
    subscription = Upkeep::Rails.subscriptions.subscriptions.first
    adapter = RecordingAdapter.new
    Upkeep::Rails.transport.connect(subscriber_id: subscription.subscriber_id, adapter: adapter)
    subscription.metadata.fetch(:shared_stream_names, []).each do |stream_name|
      Upkeep::Rails.transport.connect(subscriber_id: "shared:#{stream_name}", adapter: adapter)
    end

    _status, _headers, body = RuntimeDeliveryCardsController.action(:update).call(
      env_for("/cards/#{card.id}", method: "PATCH", params: { id: card.id, title: "Plan v2" })
    )
    collect_body(body)
    Upkeep::Rails.drain_delivery!

    assert_equal 1, adapter.bodies.size
    assert_includes adapter.bodies.first, "Plan v2"
  end

  def test_subscription_storage_changes_are_not_planned_for_delivery
    plan_events = []
    build_events = []
    plan_subscriber = ActiveSupport::Notifications.subscribe("plan.upkeep") { |event| plan_events << event }
    build_subscriber = ActiveSupport::Notifications.subscribe("build_turbo_streams.upkeep") { |event| build_events << event }

    Upkeep::Rails.deliver_changes_now!([
      delivery_change(table: "upkeep_subscriptions"),
      delivery_change(table: "upkeep_subscription_index_entries")
    ])
    Upkeep::Rails.deliver_changes!([delivery_change(table: "upkeep_subscriptions")])
    Upkeep::Rails.drain_delivery!

    assert_empty plan_events
    assert_empty build_events
  ensure
    ActiveSupport::Notifications.unsubscribe(plan_subscriber) if plan_subscriber
    ActiveSupport::Notifications.unsubscribe(build_subscriber) if build_subscriber
  end

  def test_controller_page_replay_does_not_register_another_subscription
    user = RuntimeDeliveryUser.create!(name: "Alice")
    RuntimeDeliveryCard.create!(title: "Plan")
    RuntimeDeliveryCurrent.user = user

    _status, _headers, body = RuntimeDeliveryCardsController.action(:index).call(env_for("/cards"))
    collect_body(body)
    subscription = Upkeep::Rails.subscriptions.subscriptions.first
    recipe = subscription.replay_recipe("page:rails:runtime_delivery_cards/index")

    html = recipe.render

    assert_includes html, "Plan"
    assert_equal 1, Upkeep::Rails.subscriptions.subscriptions.size
  end

  def test_change_log_capture_keeps_request_events_out_of_the_global_journal
    event = { table: "runtime_delivery_cards", changed_attributes: ["title"] }

    result, changes = Upkeep::Runtime::ChangeLog.capture do
      Upkeep::Runtime::ChangeLog.record(event)
      :captured
    end

    assert_equal :captured, result
    assert_equal [event], changes
    assert_empty Upkeep::Runtime::ChangeLog.events
  end

  private

  def env_for(path, method: "GET", params: {})
    Rack::MockRequest.env_for(path, method: method, params: params)
  end

  def collect_body(body)
    body.each.to_a.join
  ensure
    body.close if body.respond_to?(:close)
  end

  def delivery_change(table:)
    {
      type: "update",
      table: table,
      model: table.classify,
      id: "subscription-test",
      changed_attributes: ["updated_at"],
      old_values: {},
      new_values: {}
    }
  end

  def capture_notifications(name)
    events = []
    subscriber = ActiveSupport::Notifications.subscribe(name) { |event| events << event }
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def resolver
    ActionView::FixtureResolver.new(
      "runtime_delivery_cards/index.html.erb" => <<~ERB,
        <main>
          <p><%= RuntimeDeliveryCurrent.user.name %></p>
          <ul>
            <%= render partial: "runtime_delivery_cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "runtime_delivery_cards/anonymous.html.erb" => <<~ERB,
        <main>
          <ul>
            <%= render partial: "runtime_delivery_cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "runtime_delivery_cards/request_variant.html.erb" => <<~ERB,
        <main>
          <p><%= @user_agent %></p>
          <ul>
            <%= render partial: "runtime_delivery_cards/card", collection: @cards, as: :card %>
          </ul>
        </main>
      ERB
      "runtime_delivery_cards/_card.html.erb" => <<~ERB
        <li id="runtime_delivery_card_<%= card.id %>"><%= card.title %></li>
      ERB
    )
  end
end
