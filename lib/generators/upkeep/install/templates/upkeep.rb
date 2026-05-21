# frozen_string_literal: true

Upkeep::Rails.configure do |config|
  config.enabled = true
  config.subscription_store = :active_record
  config.delivery_adapter = :active_job
  config.delivery_queue = :upkeep_realtime

  # Delivery setup:
  # Upkeep uses Active Job for committed-change delivery in production. Configure
  # your app's Active Job backend normally (Solid Queue, Sidekiq, GoodJob, etc.)
  # and configure ActionCable with a shared adapter such as Solid Cable, Redis,
  # or PostgreSQL so worker broadcasts can reach web socket connections.

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
  # Example for session-backed authentication:
  #
  # config.identify :viewer, session: :user_id do
  #   # nil means this identity boundary is absent. Use absent_if for any
  #   # additional app-specific sentinel, such as false or "guest".
  #   # absent_if { |value| value.nil? || value == false }
  #   subscribe { |connection| connection.session[:user_id] }
  # end
end
