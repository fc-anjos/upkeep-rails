# frozen_string_literal: true

require "minitest/autorun"
require "action_view"
require "action_controller"
require "action_view/testing/resolvers"
require "upkeep"
require "upkeep/proof_support"

Upkeep::Rails.configure do |config|
  config.subscription_store = :memory
end
