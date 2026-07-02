# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def test_subscription_ttl_defaults_to_one_day
    assert_equal 24 * 60 * 60, Upkeep::Rails::Configuration.new.subscription_ttl
  end

  def test_subscription_ttl_is_configurable
    configuration = Upkeep::Rails::Configuration.new
    configuration.subscription_ttl = 60 * 60

    assert_equal 60 * 60, configuration.subscription_ttl
  end
end
