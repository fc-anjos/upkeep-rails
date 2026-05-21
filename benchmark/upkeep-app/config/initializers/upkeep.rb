# frozen_string_literal: true

Upkeep::Rails.configure do |config|
  config.identify :user, current: ["Current", :user] do
    subscribe { |cable| cable.current_user }
  end
end
