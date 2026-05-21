# frozen_string_literal: true

Upkeep::Rails.configure do |config|
  config.enabled = true
  config.subscription_store = :active_record

  config.identify :user, session: :u do
    subscribe { |connection| connection.session[:u] }
  end
end
