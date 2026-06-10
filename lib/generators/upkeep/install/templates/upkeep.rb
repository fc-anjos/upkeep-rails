# frozen_string_literal: true

Upkeep::Rails.configure do |config|
  app_config = Rails.application.config.upkeep

  config.enabled = app_config.fetch(:enabled, true)
  config.subscription_store = app_config.fetch(:subscription_store, Rails.env.test? ? :memory : :active_record)
  config.deliver_inline = app_config.fetch(:deliver_inline, false)

  # Delivery setup:
  # Upkeep delivers committed changes on an in-process background dispatcher in
  # every environment; no job backend is required. Broadcasts are standard
  # Action Cable broadcasts, so multi-process deployments need a cross-process
  # cable adapter (we recommend solid_cable) so a write handled by one process
  # reaches browsers connected to another. Set config.deliver_inline = true in
  # tests or console sessions that need delivery to run synchronously in the
  # caller.
  #
  # Test setup:
  # The generated test default is the in-process memory store. It follows the
  # same subscription lifecycle as ActiveRecord without requiring subscription
  # tables in every app test database. Keep at least one app/CI path on
  # :active_record when you want to exercise durable subscription rows.
  #
  # View setup:
  # No per-template annotations are required for ordinary Rails views. Upkeep
  # instruments Action View templates as they render and adds the internal
  # markers it needs for page roots, fragment roots, and safe partial collection
  # render-site containers. Keep rendering normal ERB and collection partials:
  #
  # <ul>
  #   <%%= render partial: "cards/card", collection: @cards, as: :card %>
  # </ul>
  #
  # The upkeep_frame helper remains available for advanced/generated boundaries
  # that cannot be derived from template source, but it is not part of normal
  # application setup.

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
