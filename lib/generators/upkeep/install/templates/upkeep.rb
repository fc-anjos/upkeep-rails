# frozen_string_literal: true

Rails.application.configure do
  config.upkeep.enabled = true
  config.upkeep.subscription_store = :active_record
end
