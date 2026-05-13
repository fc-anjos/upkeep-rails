# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/upkeep/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Upkeep::InstallGenerator
  destination File.expand_path("../tmp/install_generator", __dir__)

  setup :prepare_destination

  def setup
    super
    FileUtils.mkdir_p(File.join(destination_root, "app/javascript"))
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(File.join(destination_root, "app/javascript/application.js"), %(import "controllers"\n))
    File.write(File.join(destination_root, "config/importmap.rb"), %(pin "application"\n))
    File.write(File.join(destination_root, "config/routes.rb"), %(Rails.application.routes.draw do\nend\n))
  end

  def test_install_writes_subscription_storage_and_runtime_files
    run_generator

    migration = Dir[File.join(destination_root, "db/migrate/*_create_upkeep_subscriptions.rb")].first
    assert migration
    assert_file migration, /create_table :upkeep_subscriptions, id: :string/
    assert_file migration, /create_table :upkeep_subscription_index_entries/
    assert_file "config/initializers/upkeep.rb", /config\.upkeep\.enabled = true/
    assert_file "config/initializers/upkeep.rb", /config\.upkeep\.subscription_store = :active_record/
    assert_file "app/javascript/upkeep/subscription.js", /data-upkeep-subscription/
    assert_file "app/javascript/application.js", /import "@hotwired\/turbo-rails"/
    assert_file "app/javascript/application.js", %r{import "\./upkeep/subscription"}
    assert_file "config/importmap.rb", /pin "@hotwired\/turbo-rails", to: "turbo\.min\.js"/
    assert_file "config/importmap.rb", /pin "@rails\/actioncable", to: "actioncable\.esm\.js"/
    assert_file "config/routes.rb", %r{mount ActionCable\.server => "/cable"}
  end

  def test_install_is_idempotent_for_existing_wiring
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    File.write(File.join(destination_root, "db/migrate/20260101000000_create_upkeep_subscriptions.rb"), "# existing\n")
    File.write(File.join(destination_root, "app/javascript/application.js"), %(import "@hotwired/turbo-rails"\nimport "./upkeep/subscription"\n))
    File.write(File.join(destination_root, "config/importmap.rb"), %(pin "@hotwired/turbo-rails", to: "turbo.min.js"\npin "@rails/actioncable", to: "actioncable.esm.js"\n))
    File.write(File.join(destination_root, "config/routes.rb"), %(Rails.application.routes.draw do\n  mount ActionCable.server => "/cable"\nend\n))

    run_generator

    assert_equal 1, Dir[File.join(destination_root, "db/migrate/*create_upkeep_subscriptions.rb")].size
    assert_equal 1, File.read(File.join(destination_root, "app/javascript/application.js")).scan("upkeep/subscription").size
    assert_equal 1, File.read(File.join(destination_root, "app/javascript/application.js")).scan("@hotwired/turbo-rails").size
    assert_equal 1, File.read(File.join(destination_root, "config/importmap.rb")).scan("@rails/actioncable").size
    assert_equal 1, File.read(File.join(destination_root, "config/importmap.rb")).scan("@hotwired/turbo-rails").size
    assert_equal 1, File.read(File.join(destination_root, "config/routes.rb")).scan("ActionCable.server").size
  end
end
