# frozen_string_literal: true

Rails.application.configure do
  config.upkeep.enabled = true
  config.upkeep.subscription_store = :active_record
  config.upkeep.delivery_adapter = :active_job
  config.upkeep.delivery_queue = :upkeep_realtime

  # Delivery setup:
  # Upkeep uses Active Job for committed-change delivery in production. Configure
  # your app's Active Job backend normally (Solid Queue, Sidekiq, GoodJob, etc.)
  # and configure ActionCable with a shared adapter such as Solid Cable, Redis,
  # or PostgreSQL so worker broadcasts can reach web socket connections.

  # Identity setup:
  # Upkeep does not infer user/account identity by naming convention. Declare
  # each identity that should partition live updates, and resolve the same
  # identity from ActionCable when the browser subscribes.
  #
  # Example for Current.user plus ApplicationCable identified_by :current_user:
  #
  # Upkeep::Rails.configure do |upkeep|
  #   upkeep.identify :user, current: ["Current", :user] do
  #     subscribe { |cable| cable.current_user }
  #   end
  # end
  #
  # Example for session-backed authentication:
  #
  # Upkeep::Rails.configure do |upkeep|
  #   upkeep.identify :user, session: :user_id do
  #     subscribe { |cable| cable.request.session[:user_id] }
  #   end
  # end
end
