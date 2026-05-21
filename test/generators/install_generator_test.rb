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
    assert_file migration, /t\.json :recorder_snapshot, null: false/
    assert_file migration, /create_table :upkeep_subscription_index_entries/
    assert_file migration, /t\.string :dependency_source, null: false/
    assert_file migration, /t\.string :lookup_table, null: false/
    assert_file migration, /t\.json :lookup_record_id_snapshot/
    assert_file migration, /t\.string :lookup_attribute, null: false/
    assert_file migration, /t\.string :dependency_table, null: false/
    assert_file migration, /t\.json :dependency_metadata_snapshot/
    assert_file migration, /t\.json :owner_ids_snapshot, null: false/
    assert_file migration, /create_table :upkeep_subscription_shape_index_entries/
    assert_file migration, /t\.string :subscription_shape_key, null: false/
    assert_file migration, /add_index :upkeep_subscription_shape_index_entries, :subscription_shape_key/
    assert_file "config/initializers/upkeep.rb", /Upkeep::Rails\.configure do \|config\|/
    assert_file "config/initializers/upkeep.rb", /config\.enabled = true/
    assert_file "config/initializers/upkeep.rb", /config\.subscription_store = :active_record/
    assert_file "config/initializers/upkeep.rb", /config\.delivery_adapter = :active_job/
    assert_file "config/initializers/upkeep.rb", /config\.delivery_queue = :upkeep_realtime/
    assert_file "config/initializers/upkeep.rb", /Delivery setup:/
    assert_file "config/initializers/upkeep.rb", /Identity setup:/
    assert_file "config/initializers/upkeep.rb", /config\.identify :viewer, current: \["Current", :user\]/
    assert_file "config/initializers/upkeep.rb", /absent_if/
    refute_match(/request\.session/, File.read(File.join(destination_root, "config/initializers/upkeep.rb")))
    assert_file "app/javascript/upkeep/subscription.js", /data-upkeep-subscription/
    assert_file "app/javascript/upkeep/subscription.js", /activation_token: payload\.activation_token/
    assert_file "app/javascript/upkeep/subscription.js", /connectStreamSource/
    assert_file "app/javascript/upkeep/subscription.js", /disconnectStreamSource/
    assert_file "app/javascript/upkeep/subscription.js", /subscription rejected by the server/
    refute_match(/document\.write/, File.read(File.join(destination_root, "app/javascript/upkeep/subscription.js")))
    assert_file "app/javascript/application.js", /import "@hotwired\/turbo-rails"/
    assert_file "app/javascript/application.js", %r{import "upkeep/subscription"}
    assert_file "config/importmap.rb", /pin "@hotwired\/turbo-rails", to: "turbo\.min\.js"/
    assert_file "config/importmap.rb", /pin "@rails\/actioncable", to: "actioncable\.esm\.js"/
    assert_file "config/importmap.rb", %r{pin "upkeep/subscription", to: "upkeep/subscription\.js"}
    assert_file "config/routes.rb", %r{mount ActionCable\.server => "/cable"}
  end

  def test_install_is_idempotent_for_existing_wiring
    FileUtils.mkdir_p(File.join(destination_root, "db/migrate"))
    File.write(File.join(destination_root, "db/migrate/20260101000000_create_upkeep_subscriptions.rb"), "# existing\n")
    File.write(File.join(destination_root, "app/javascript/application.js"), %(import "@hotwired/turbo-rails"\nimport "upkeep/subscription"\n))
    File.write(File.join(destination_root, "config/importmap.rb"), %(pin "@hotwired/turbo-rails", to: "turbo.min.js"\npin "@rails/actioncable", to: "actioncable.esm.js"\npin "upkeep/subscription", to: "upkeep/subscription.js"\n))
    File.write(File.join(destination_root, "config/routes.rb"), %(Rails.application.routes.draw do\n  mount ActionCable.server => "/cable"\nend\n))

    run_generator

    assert_equal 1, Dir[File.join(destination_root, "db/migrate/*create_upkeep_subscriptions.rb")].size
    assert_equal 1, File.read(File.join(destination_root, "app/javascript/application.js")).scan(%r{import "upkeep/subscription"}).size
    assert_equal 1, File.read(File.join(destination_root, "app/javascript/application.js")).scan("@hotwired/turbo-rails").size
    assert_equal 1, File.read(File.join(destination_root, "config/importmap.rb")).scan("@rails/actioncable").size
    assert_equal 1, File.read(File.join(destination_root, "config/importmap.rb")).scan("@hotwired/turbo-rails").size
    assert_equal 1, File.read(File.join(destination_root, "config/importmap.rb")).scan(%r{pin "upkeep/subscription"}).size
    assert_equal 1, File.read(File.join(destination_root, "config/routes.rb")).scan("ActionCable.server").size
  end

  def test_install_prints_identity_setup_guidance_when_identity_usage_is_detected
    FileUtils.mkdir_p(File.join(destination_root, "app/models"))
    File.write(File.join(destination_root, "app/models/current.rb"), <<~RUBY)
      class Current < ActiveSupport::CurrentAttributes
        attribute :user
      end
    RUBY
    FileUtils.mkdir_p(File.join(destination_root, "app/controllers"))
    File.write(File.join(destination_root, "app/controllers/application_controller.rb"), <<~RUBY)
      class ApplicationController < ActionController::Base
        before_action { Current.user = User.find_by(id: session[:user_id]) }
      end
    RUBY

    generator = Upkeep::InstallGenerator.new([], {}, destination_root: destination_root)
    usages = generator.send(:detected_identity_usages)
    output, = capture_io { generator.show_identity_setup_guidance }

    assert_includes usages, "Current.user"
    assert_includes usages, "session[:user_id]"
    assert_includes output, "Identity setup required"
    assert_includes output, "Current.user"
    assert_includes output, "session[:user_id]"
    assert_includes output, "Upkeep does not infer subscriber identity by naming convention."
    assert_includes output, "undeclared non-absent CurrentAttributes"
  end
end
