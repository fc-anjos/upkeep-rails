# frozen_string_literal: true

require "test_helper"
require "rails/railtie"
require "upkeep/rails/railtie"

class RailtieTest < Minitest::Test
  def test_rake_task_is_false_when_only_rake_namespace_is_loaded
    previous_rake = Object.const_get(:Rake) if Object.const_defined?(:Rake)
    Object.send(:remove_const, :Rake) if Object.const_defined?(:Rake)
    Object.const_set(:Rake, Module.new)

    refute Upkeep::Rails::Railtie.rake_task?
  ensure
    Object.send(:remove_const, :Rake) if Object.const_defined?(:Rake)
    Object.const_set(:Rake, previous_rake) if defined?(previous_rake) && previous_rake
  end
end
