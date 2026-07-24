# frozen_string_literal: true

require "minitest/autorun"
require "action_view"
require "action_controller"
require "action_view/testing/resolvers"
require "upkeep"
require "upkeep/proof_support"
require_relative "support/arel_query_analysis_oracle"

Upkeep::Rails.configure do |config|
  config.subscription_store = :memory
end
