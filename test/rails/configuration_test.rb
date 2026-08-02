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

  def test_request_activation_defaults_to_all
    assert_equal :all, Upkeep::Rails::Configuration.new.request_activation
  end

  def test_request_activation_accepts_opt_in
    configuration = Upkeep::Rails::Configuration.new

    configuration.request_activation = :opt_in

    assert_equal :opt_in, configuration.request_activation
  end

  def test_request_activation_rejects_unknown_values
    configuration = Upkeep::Rails::Configuration.new

    error = assert_raises(Upkeep::Rails::ConfigurationError) do
      configuration.request_activation = :sometimes
    end

    assert_match(/expected one of all, opt_in/, error.message)
  end
end
