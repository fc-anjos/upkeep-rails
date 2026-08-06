require_relative "test_helper"

# Framework-infrastructure session keys (flash, CSRF token, warden.*) are
# read on essentially every request of every real Rails app; observing them
# would identity-taint every page and Tier S could never engage anywhere.
# Keyed reads of those keys are sanctioned; app keys still taint; whole-
# session reads still taint.
class AmbientInfrastructureTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  class ProbeController < ActionController::Base
    include RefreshSync::Capture
    refresh_sync

    def infra
      session["flash"]
      session["_csrf_token"]
      session["warden.user.user.key"]
      @cards = Card.all.to_a
      render inline: "<ul><% @cards.each do |c| %><li><%= c.title %></li><% end %></ul>", layout: false
    end

    def app_key
      session[:banner]
      @cards = Card.all.to_a
      render inline: "<ul><% @cards.each do |c| %><li><%= c.title %></li><% end %></ul>", layout: false
    end
  end

  def setup
    super
    Rails.application.routes.draw do
      post "/login", to: "sessions#create"
      get "/probe/infra", to: "ambient_infrastructure_test/probe#infra"
      get "/probe/app_key", to: "ambient_infrastructure_test/probe#app_key"
    end
  end

  def teardown
    Rails.application.reload_routes!
  end

  def test_infrastructure_session_keys_do_not_taint
    get "/probe/infra"
    assert_response :success
    assert response.headers["X-RefreshSync-Stream"], "capture should register"
    recording = RefreshSync::Capture.last_recording
    assert_empty recording.ambient, "flash/csrf/warden reads must not identity-taint"
  end

  def test_app_session_keys_still_taint
    get "/probe/app_key"
    assert_response :success
    recording = RefreshSync::Capture.last_recording
    assert_includes recording.ambient, :session_read
  end

  def test_whole_session_reads_still_taint
    RefreshSync::Ambient.observe(:probe) # sanity: helper exists
    get "/probe/infra" # warm session
    sess = open_session
    sess.post "/login", params: { user_id: @alice.id }
    # to_h during capture taints regardless of keys
    ProbeController.class_eval do
      def infra
        session.to_h
        @cards = Card.all.to_a
        render inline: "ok", layout: false
      end
    end
    sess.get "/probe/infra"
    recording = RefreshSync::Capture.last_recording
    assert_includes recording.ambient, :session_read
  ensure
    ProbeController.class_eval do
      def infra
        session["flash"]
        session["_csrf_token"]
        session["warden.user.user.key"]
        @cards = Card.all.to_a
        render inline: "<ul><% @cards.each do |c| %><li><%= c.title %></li><% end %></ul>", layout: false
      end
    end
  end
end
