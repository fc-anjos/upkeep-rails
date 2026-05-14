# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require_relative "../config/environment"
require "rails/test_help"
require Rails.root.join("..", "shared", "lobsters_seed_data").expand_path
require Rails.root.join("..", "shared", "lobsters_integration_helpers").expand_path

class ActiveSupport::TestCase
  parallelize(workers: 1)
  self.use_transactional_tests = false
end

class ActionDispatch::IntegrationTest
  include LobstersIntegrationHelpers
end
