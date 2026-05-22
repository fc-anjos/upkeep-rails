# frozen_string_literal: true

Upkeep::Rails.configure do |config|
  app_config = Rails.application.config.upkeep

  config.enabled = app_config.fetch(:enabled, true)
  config.subscription_store = app_config.fetch(:subscription_store, Rails.env.test? ? :memory : :active_record)
  config.delivery_adapter = app_config.fetch(:delivery_adapter, Rails.env.production? ? :active_job : :async)
  config.delivery_queue = app_config.fetch(:delivery_queue, :upkeep_realtime)

  # Delivery setup:
  # Upkeep uses Active Job for committed-change delivery in production and async
  # in development/test. Configure your app's Active Job backend normally
  # (Solid Queue, Sidekiq, GoodJob, etc.) and configure ActionCable with a shared
  # adapter such as Solid Cable, Redis, or PostgreSQL so worker broadcasts can
  # reach web socket connections.
  #
  # Test setup:
  # The generated test default is the in-process memory store. It follows the
  # same subscription lifecycle as ActiveRecord without requiring subscription
  # tables in every app test database. Keep at least one app/CI path on
  # :active_record when you want to exercise durable subscription rows.
  #
  # View setup:
  # Wrap collection regions that should receive narrowed live updates with the
  # upkeep_frame block helper, and mark page/partial roots with the generated
  # frame ids:
  #
  # <%%= upkeep_frame "cards" do %>
  #   <ul data-upkeep-render-site="cards">
  #     <%%= render partial: "cards/card", collection: @cards, as: :card %>
  #   </ul>
  # <%% end %>
  #
  # In normal ERB templates, prefer the output form above: <%%= upkeep_frame ... %>.
  # Calling upkeep_frame without a block raises an ArgumentError.

  # Identity setup:
  # Upkeep does not infer subscriber identity by naming convention. Declare each
  # identity boundary that should partition live updates, and resolve the same
  # boundary from ActionCable when the browser subscribes.
  #
  # Example for Current.user plus ApplicationCable identified_by :current_user:
  #
  # config.identify :viewer, current: ["Current", :user] do
  #   subscribe { |connection| connection.current_user }
  # end
  #
  # Example for Devise/Warden current_user:
  #
  # config.identify :viewer, warden: :user do
  #   subscribe { |connection| connection.current_user }
  # end
  #
  # Example for session-backed authentication:
  #
  # config.identify :viewer, session: :user_id do
  #   # nil means this identity boundary is absent. Use absent_if for any
  #   # additional app-specific sentinel, such as false or "guest".
  #   # absent_if { |value| value.nil? || value == false }
  #   subscribe { |connection| connection.session[:user_id] }
  # end
end
