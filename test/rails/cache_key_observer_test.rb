# frozen_string_literal: true

require "test_helper"

class CacheKeyObserverCard < ActiveRecord::Base
  self.table_name = "cache_key_observer_cards"
end

class CacheKeyObserverTest < Minitest::Test
  def setup
    Upkeep::Rails::Install.call

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.verbose = false

    ActiveRecord::Schema.define do
      create_table :cache_key_observer_cards, force: true do |table|
        table.string :title, null: false
        table.timestamps
      end
    end
  end

  def test_cache_key_with_version_records_updated_at_dependency
    card = CacheKeyObserverCard.create!(title: "Plan")

    _, recorder = Upkeep::Runtime::Observation.capture_request do
      card.cache_key_with_version
    end

    deps = recorder.graph.dependencies_for(Upkeep::Runtime::Recorder::REQUEST_NODE_ID)
    cache_dep = deps.find do |dep|
      dep.is_a?(Upkeep::Dependencies::ActiveRecordAttribute) &&
        dep.key.fetch(:table) == "cache_key_observer_cards" &&
        dep.key.fetch(:id) == card.id &&
        dep.key.fetch(:attribute) == "updated_at"
    end

    refute_nil cache_dep, "expected cache_key_with_version to register an updated_at dependency on the record"
  end

  def test_cache_key_with_version_does_not_record_for_new_record
    card = CacheKeyObserverCard.new(title: "Plan")

    _, recorder = Upkeep::Runtime::Observation.capture_request do
      card.cache_key_with_version
    end

    deps = recorder.graph.dependencies_for(Upkeep::Runtime::Recorder::REQUEST_NODE_ID)
    cache_dep = deps.find do |dep|
      dep.is_a?(Upkeep::Dependencies::ActiveRecordAttribute) &&
        dep.key.fetch(:table) == "cache_key_observer_cards" &&
        dep.key.fetch(:attribute) == "updated_at"
    end

    assert_nil cache_dep, "expected no dependency for new (unsaved) records"
  end

  def test_cache_key_with_version_no_op_outside_capture
    card = CacheKeyObserverCard.create!(title: "Plan")

    assert_match(%r{\Acache_key_observer_cards/#{card.id}-\d+}, card.cache_key_with_version)
  end
end
