# frozen_string_literal: true

require "test_helper"

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

  def update
    RuntimeDeliveryCard.find(params.fetch(:id)).update!(title: params.fetch(:title))
    head :ok
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

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
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
  end

  def test_get_registers_subscription_and_injects_client_marker
    user = RuntimeDeliveryUser.create!(name: "Alice")
    RuntimeDeliveryCard.create!(title: "Plan")
    RuntimeDeliveryCurrent.user = user

    _status, _headers, body = RuntimeDeliveryCardsController.action(:index).call(env_for("/cards"))
    html = collect_body(body)
    subscription = Upkeep::Rails.subscriptions.subscriptions.first

    assert subscription
    assert_equal subscription.subscriber_id, Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: user).subscriber_id
    assert_includes html, "data-upkeep-subscription"
    assert_includes html, subscription.id
    assert_includes html, Upkeep::Rails::Cable::SubscriberIdentity.for_identifiers(current_user: user).stream_name
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

    _status, _headers, body = RuntimeDeliveryCardsController.action(:update).call(
      env_for("/cards/#{card.id}", method: "PATCH", params: { id: card.id, title: "Plan v2" })
    )
    collect_body(body)

    assert_equal 1, adapter.bodies.size
    assert_includes adapter.bodies.first, "Plan v2"
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
      "runtime_delivery_cards/_card.html.erb" => <<~ERB
        <li id="runtime_delivery_card_<%= card.id %>"><%= card.title %></li>
      ERB
    )
  end
end
