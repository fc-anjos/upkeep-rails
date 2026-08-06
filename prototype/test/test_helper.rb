ENV["RAILS_ENV"] = "test"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_cable/engine"
require "turbo-rails"
require "minitest/autorun"

require "refresh_sync"

PROTO_ROOT = File.expand_path("..", __dir__)

class ProofApp < Rails::Application
  config.root = PROTO_ROOT
  config.load_defaults 8.0
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "refresh-sync-proof" * 2
  config.logger = Logger.new(IO::NULL)
  config.active_record.maintain_test_schema = false
  config.action_cable.cable = { "adapter" => "test" }
  config.action_controller.allow_forgery_protection = false
end

ProofApp.initialize!

ActionCable.server.config.cable = { "adapter" => "test" }
ActionCable.server.config.logger = Logger.new(IO::NULL)

db_path = File.join(PROTO_ROOT, "tmp", "proof.sqlite3")
FileUtils.mkdir_p(File.dirname(db_path))
FileUtils.rm_f(db_path)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db_path)

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :boards, force: true do |t|
    t.string :name
  end
  create_table :cards, force: true do |t|
    t.integer :board_id
    t.integer :user_id
    t.string :title
    t.string :status, default: "open"
    t.date :due_on
    t.string :uid
  end
  create_table :users, force: true do |t|
    t.string :name
    t.string :role, default: "user"
    t.boolean :beta, default: false
  end
end

RefreshSync.install!
RefreshSync::ActiveRecordStore.setup!

# Provenance: templates under test/views compile through Herb with the
# node-bracketing visitor (byte-identical output); Pulse fixture views under
# test/views/pulse additionally get data-rs-node stamps for region delivery.
RefreshSync::Provenance.instrument_paths = [File.join(PROTO_ROOT, "test", "views")]
RefreshSync::Provenance.stamp_paths = [File.join(PROTO_ROOT, "test", "views", "pulse")]
RefreshSync::Provenance.install!

class Board < ActiveRecord::Base
  has_many :cards
end

class Card < ActiveRecord::Base
  belongs_to :board, optional: true
end

class User < ActiveRecord::Base
  has_many :cards

  def admin? = role == "admin"
end

class Current < ActiveSupport::CurrentAttributes
  attribute :locale
end

# Bare renderer for scrubbed Tier S renders: same views, but no session, no
# cookies, no current_user helper, nothing viewer-specific.
class ScrubbedController < ActionController::Base
  prepend_view_path File.join(PROTO_ROOT, "test", "views")
end
RefreshSync.renderer_class = ScrubbedController

RefreshSync.viewer_resolver = ->(request) do
  user = User.find_by(id: request.session[:user_id])
  user && RefreshSync::Viewer.new(id: user.id, role: user.role)
end

class SessionsController < ActionController::Base
  def create
    session[:user_id] = params[:user_id]
    session[:secret] = params[:secret] if params[:secret]
    session[:tz] = params[:tz] if params[:tz]
    session[:banner] = params[:banner] if params[:banner]
    head :no_content
  end
end

class BoardsController < ActionController::Base
  include RefreshSync::Capture
  refresh_sync

  def show
    @board = Board.find(params[:id])
    @cards = @board.cards.where(status: "open").to_a
    render inline: <<~ERB, layout: false
      <h1><%= @board.name %></h1>
      <ul><% @cards.each do |card| %><li><%= card.title %></li><% end %></ul>
    ERB
  end

  def all_cards
    @cards = Card.all.to_a
    render inline: "<ul><% @cards.each do |c| %><li><%= c.title %></li><% end %></ul>", layout: false
  end

  # Write-on-read page (mark-as-read): idempotent, so refresh-triggered
  # re-GETs converge instead of cascading forever.
  def inbox
    unread = Card.find_by(status: "open")
    unread&.update!(status: "read")
    @cards = Card.all.to_a
    render inline: "<ul><% @cards.each do |c| %><li><%= c.title %>:<%= c.status %></li><% end %></ul>", layout: false
  end
end

# Upkeep's write convention: POST + head :no_content. The broadcast is the
# single source of UI truth for everyone, including the tab that wrote.
class CardsApiController < ActionController::Base
  def create
    Card.create!(params.permit(:board_id, :title, :status, :due_on, :uid))
    head :no_content
  end
end

# Adversarial + legitimate shared-surface pages.
class SurfacesController < ActionController::Base
  include RefreshSync::Capture
  prepend_view_path File.join(PROTO_ROOT, "test", "views")
  refresh_sync

  helper_method :current_user

  # Sanctioned identity declaration: reads the session through the
  # unobserved escape hatch, exactly like a real auth integration would.
  def current_user
    @current_user ||= RefreshSync::Ambient.unobserved { User.find_by(id: session[:user_id]) }
  end

  def shared_board
    render template: "surfaces/shared_board", layout: false
  end

  def dashboard
    render template: "surfaces/dashboard", layout: false
  end

  def tz
    render template: "surfaces/tz", layout: false
  end

  def badge
    render template: "surfaces/badge", layout: false
  end

  def threadlocal
    # Deliberate smuggle: copies session state into Thread.current without
    # touching the observed choke points.
    Thread.current[:banner] = RefreshSync::Ambient.unobserved { session[:banner] }
    render template: "surfaces/threadlocal", layout: false
  end

  def flagged
    render template: "surfaces/flagged", layout: false
  end

  def vip
    render template: "surfaces/vip", layout: false
  end
end

Rails.application.routes.draw do
  post "/login", to: "sessions#create"
  post "/cards_api", to: "cards_api#create"
  get "/boards/:id", to: "boards#show"
  get "/cards", to: "boards#all_cards"
  get "/inbox", to: "boards#inbox"
  get "/shared_board", to: "surfaces#shared_board"
  get "/dashboard", to: "surfaces#dashboard"
  get "/tz", to: "surfaces#tz"
  get "/badge", to: "surfaces#badge"
  get "/threadlocal", to: "surfaces#threadlocal"
  get "/flagged", to: "surfaces#flagged"
  get "/vip", to: "surfaces#vip"
end

module ProofHelpers
  WINDOW = 0.3

  def setup
    RefreshSync.store = RefreshSync::MemoryStore.new
    RefreshSync.debouncer = RefreshSync::Debouncer.new(window: WINDOW)
    RefreshSync.registry = RefreshSync::SurfaceRegistry.new
    RefreshSync.deploy_key = "deploy-1"
    RefreshSync.require_role_diversity = true
    RefreshSync.reset_stats!
    RefreshSync::Coercion.reset!
    RefreshSync::ActiveRecordStore.wipe!
    ActionCable.server.pubsub.clear
    Board.delete_all
    Card.delete_all
    User.delete_all
    @board1 = Board.create!(name: "Board One")
    @board2 = Board.create!(name: "Board Two")
    @card1 = Card.create!(board: @board1, title: "First", status: "open")
    @card2 = Card.create!(board: @board2, title: "Other", status: "open")
    @alice = User.create!(name: "SENTINEL_USER_ALICE", role: "user")
    @bob = User.create!(name: "SENTINEL_USER_BOB", role: "user")
    @carol = User.create!(name: "SENTINEL_USER_CAROL", role: "admin")
  end

  def broadcasts(stream)
    ActionCable.server.pubsub.broadcasts(stream)
  end

  def all_broadcast_payloads
    (ActionCable.server.pubsub.instance_variable_get(:@channels_data) || {}).values.flatten
  end

  # Ground-truth leak assertion: no broadcast, on any stream, ever contains
  # viewer-planted sentinel content. Independent of any mechanism above.
  def assert_no_sentinel_broadcast
    all_broadcast_payloads.each do |payload|
      refute_match(/SENTINEL/, payload, "sentinel leaked into a broadcast: #{payload[0, 200]}")
    end
  end

  # A logged-in browsing session for one user.
  def session_for(user, tz: nil, banner: nil)
    sess = open_session
    sess.post "/login", params: {
      user_id: user.id, secret: "SENTINEL_SESSION_#{user.name}", tz: tz, banner: banner
    }.compact
    sess
  end

  def surface(name) = RefreshSync.registry.lookup(name)

  # Simulate a distinct app process: its own store/registry/debouncer
  # instances (sharing the DB and the cable, as real processes would).
  SimProcess = Struct.new(:store, :registry, :debouncer, keyword_init: true)

  def sim_process(window: WINDOW, claimer: RefreshSync::DbClaimer.new)
    SimProcess.new(
      store: RefreshSync::ActiveRecordStore.new,
      registry: RefreshSync::ActiveRecordSurfaceRegistry.new,
      debouncer: RefreshSync::Debouncer.new(window: window, claimer: claimer)
    )
  end

  def in_process(sim)
    RefreshSync.store = sim.store
    RefreshSync.registry = sim.registry
    RefreshSync.debouncer = sim.debouncer
    yield
  end

  def visit_board(board)
    get "/boards/#{board.id}"
    assert_response :success
    response.headers["X-RefreshSync-Stream"].tap { |s| assert s, "capture should register a cohort" }
  end

  def drain_debounce
    sleep WINDOW + 0.25
  end

  # Wait until the stream has at least `count` broadcasts, then let the
  # debounce window drain and assert the count is exact (no extras).
  def assert_refreshes(stream, count, timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while broadcasts(stream).size < count
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    sleep WINDOW + 0.2
    assert_equal count, broadcasts(stream).size,
      "expected exactly #{count} refresh(es) on #{stream}"
    broadcasts(stream).each do |payload|
      tag = ActiveSupport::JSON.decode(payload)
      assert_includes tag, %(action="refresh"), "broadcast should be a Turbo refresh"
    end
  end

  def assert_no_refresh(stream)
    sleep WINDOW + 0.3
    assert_equal 0, broadcasts(stream).size, "expected no refresh on #{stream}"
  end
end
