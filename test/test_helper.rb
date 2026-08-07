ENV["RAILS_ENV"] = "test"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "active_job/railtie"
require "action_cable/engine"
require "turbo-rails"
require "minitest/autorun"

require "upkeep"

PROTO_ROOT = File.expand_path("..", __dir__)

class ProofApp < Rails::Application
  config.root = PROTO_ROOT
  # The 7.1 CI leg boots the same harness; load the newest defaults the
  # running Rails actually knows.
  config.load_defaults [Rails::VERSION::STRING.to_f, 8.0].min
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "upkeep-rails-proof" * 2
  config.logger = Logger.new(IO::NULL)
  config.active_record.maintain_test_schema = false
  config.action_cable.cable = { "adapter" => "test" }
  config.action_controller.allow_forgery_protection = false
  # Re-raise request exceptions (a bare Rails::Application defaults to
  # rendering a 500 page): strict-mode LivenessLost must reach the test.
  config.action_dispatch.show_exceptions = :none
  config.action_controller.perform_caching = true
  config.cache_store = :memory_store
  config.active_job.queue_adapter = :inline
end

Mime::Type.register "application/x-llm", :llm unless Mime[:llm]

ProofApp.initialize!

ActionCable.server.config.cable = { "adapter" => "test" }
ActionCable.server.config.logger = Logger.new(IO::NULL)

db_path = File.join(PROTO_ROOT, "tmp", "proof.sqlite3")
FileUtils.mkdir_p(File.dirname(db_path))
FileUtils.rm_f(db_path)
# Version coupling (ledger): before 7.2 a thread leases its connection for
# its whole life instead of per-query, so the multi-sim-process tests
# exhaust the default pool of 5 on 7.1. A wide pool + timeout keeps the
# same tests honest on both legs.
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3", database: db_path, pool: 25, timeout: 5000
)

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
  # Infrastructure tables (ignore-list fixtures).
  create_table :sessions, force: true do |t|
    t.string :session_id
    t.text :data
  end
  create_table :audits, force: true do |t|
    t.string :action
  end
  # Pulse-shaped fixture: a positioned, Discard-style list.
  create_table :items, force: true do |t|
    t.string :title
    t.integer :position
    t.datetime :discarded_at
  end
end

Upkeep.install!
Upkeep::ActiveRecordStore.setup!

# Provenance: templates under test/views compile through Herb with the
# node-bracketing visitor (byte-identical output); Pulse fixture views under
# test/views/pulse additionally get data-upkeep-node stamps for region delivery.
Upkeep::Provenance.instrument_paths = [File.join(PROTO_ROOT, "test", "views")]
Upkeep::Provenance.stamp_paths = [File.join(PROTO_ROOT, "test", "views", "pulse")]
Upkeep::Provenance.install!

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

class SessionRecord < ActiveRecord::Base
  self.table_name = "sessions"
end

# Discard-style: a default scope every query inherits (Pulse's `kept`).
class Item < ActiveRecord::Base
  default_scope { where(discarded_at: nil) }
end

class AuditRecord < ActiveRecord::Base
  self.table_name = "audits"
end

class SidekiqStyleJob < ActiveJob::Base
  # Pulse's chatbot pattern: a job drives the app's own controllers through
  # an in-process integration session, authenticated as a real user.
  def perform(session, path)
    session.get(path)
  end
end

# Bare renderer for scrubbed Tier S renders: same views, but no session, no
# cookies, no current_user helper, nothing viewer-specific.
class ScrubbedController < ActionController::Base
  prepend_view_path File.join(PROTO_ROOT, "test", "views")
end
Upkeep.renderer_class = ScrubbedController

Upkeep.viewer_resolver = ->(request) do
  user = User.find_by(id: request.session[:user_id])
  user && Upkeep::Viewer.new(id: user.id, role: user.role)
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
  include Upkeep::Capture
  upkeep

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
    # A real <body> (like any real app layout), so the browser smoke test
    # exercises subscription-tag injection the way a real app would.
    render inline: "<html><body><ul><% @cards.each do |c| %><li><%= c.title %>:<%= c.status %></li><% end %></ul></body></html>", layout: false
  end
end

# Read-door fixtures: pages whose ONLY dependency arrives through a
# non-materializing read door (calculate/pluck/exists?/statement cache), and
# audit fixtures that read through a deliberately unhooked path.
class ReadDoorsController < ActionController::Base
  include Upkeep::Capture
  upkeep

  def open_count
    @open = Card.where(status: "open").count
    render inline: "<p>Open: <%= @open %></p>", layout: false
  end

  def open_titles
    @titles = Card.where(status: "open").pluck(:title)
    render inline: "<p><%= @titles.join(', ') %></p>", layout: false
  end

  def any_open
    @any = Card.where(status: "open").exists?
    render inline: "<p><%= @any ? 'yes' : 'no' %></p>", layout: false
  end

  def lost_card
    @card = Card.find_by(uid: "lost-uid") # statement-cache path, nil result
    render inline: "<p><%= @card ? @card.title : 'missing' %></p>", layout: false
  end

  # Simulated unhooked read doors for the completeness audit: raw SELECTs
  # that no door accounts for — one attributable through the "Model Action"
  # query-name convention, one anonymous.
  def raw_named
    @count = ActiveRecord::Base.connection
                               .select_all("SELECT COUNT(*) AS c FROM cards", "Card Probe")
                               .first["c"]
    render inline: "<p>Raw: <%= @count %></p>", layout: false
  end

  def raw_anonymous
    @count = ActiveRecord::Base.connection
                               .select_all("SELECT COUNT(*) AS c FROM cards")
                               .first["c"]
    render inline: "<p>Raw: <%= @count %></p>", layout: false
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

# Ignore-list misuse fixture: a reactive page that reads the audits table.
class AuditLogsController < ActionController::Base
  include Upkeep::Capture
  upkeep

  def index
    @audits = AuditRecord.all.to_a
    render inline: "<ul><% @audits.each do |a| %><li><%= a.action %></li><% end %></ul>", layout: false
  end
end

# Pulse-shaped fixture: personalized layout chrome around a shared,
# paginated, Discard-scoped list with a cached aggregate fragment and a
# per-viewer tag inside the shared partial (the personal island).
class PulseController < ActionController::Base
  include Upkeep::Capture
  prepend_view_path File.join(PROTO_ROOT, "test", "views")
  layout "pulse"
  upkeep

  helper_method :current_user

  def current_user
    @current_user ||= Upkeep::Ambient.unobserved { User.find_by(id: session[:user_id]) }
  end

  def board
    render template: "pulse/board"
  end

  # Row-identity fail-closed fixture: the loop skips a row, so the rendered
  # iteration count disagrees with the loaded id count and per-row identity
  # must void itself.
  def skip_board
    render template: "pulse/skip_board"
  end

  # Unbroadcastable-region fixture: a cache block directly in flow with no
  # enclosing byte-shared element.
  def bare_board
    render template: "pulse/bare_board"
  end

  # Same page plus a controller-level read OUTSIDE any template node — the
  # coherence case: writes to the pinned item are NOT covered by region
  # broadcasts and must refresh.
  def board_with_pin
    @pinned = Item.find(params[:pin].to_i)
    render template: "pulse/board"
  end
end

# Fragment-cache fixture: card list read INSIDE a cache block.
class CachedBoardsController < ActionController::Base
  include Upkeep::Capture
  prepend_view_path File.join(PROTO_ROOT, "test", "views")
  upkeep

  def show
    @board_id = params[:id].to_i
    render template: "cached/board", layout: false
  end
end

# Adversarial + legitimate shared-surface pages.
class SurfacesController < ActionController::Base
  include Upkeep::Capture
  prepend_view_path File.join(PROTO_ROOT, "test", "views")
  upkeep

  helper_method :current_user

  # Sanctioned identity declaration: reads the session through the
  # unobserved escape hatch, exactly like a real auth integration would.
  def current_user
    @current_user ||= Upkeep::Ambient.unobserved { User.find_by(id: session[:user_id]) }
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
    Thread.current[:banner] = Upkeep::Ambient.unobserved { session[:banner] }
    render template: "surfaces/threadlocal", layout: false
  end

  def flagged
    render template: "surfaces/flagged", layout: false
  end

  def vip
    render template: "surfaces/vip", layout: false
  end

  # Same surface inside a page with a real <body>, so subscription-tag
  # injection (and its per-member exclusion) is observable in the response.
  def vip_page
    render template: "surfaces/vip", layout: "bare"
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
  get "/vip_page", to: "surfaces#vip_page"
  get "/audit_log", to: "audit_logs#index"
  get "/doors/open_count", to: "read_doors#open_count"
  get "/doors/open_titles", to: "read_doors#open_titles"
  get "/doors/any_open", to: "read_doors#any_open"
  get "/doors/lost_card", to: "read_doors#lost_card"
  get "/doors/raw_named", to: "read_doors#raw_named"
  get "/doors/raw_anonymous", to: "read_doors#raw_anonymous"
  get "/cached_board/:id", to: "cached_boards#show"
  get "/pulse/board", to: "pulse#board"
  get "/pulse/skip_board", to: "pulse#skip_board"
  get "/pulse/bare_board", to: "pulse#bare_board"
  get "/pulse/board_with_pin", to: "pulse#board_with_pin"
end

module ProofHelpers
  WINDOW = 0.3

  def setup
    Upkeep.store = Upkeep::MemoryStore.new
    Upkeep.debouncer = Upkeep::Debouncer.new(window: WINDOW)
    Upkeep.registry = Upkeep::SurfaceRegistry.new
    Upkeep.deploy_key = "deploy-1"
    Upkeep.require_role_diversity = true
    Upkeep.payload_limit = nil
    Upkeep.ignored_tables = nil
    Upkeep.dispatch_interlock = nil
    Upkeep.clock = nil
    # Most fixture pages render bare fragments (no <body>), which strict
    # mode correctly reports as activation-impossible. Tests that exercise
    # injection re-enable it (with_auto_subscribe) on body-bearing pages.
    Upkeep::Streams.auto_subscribe = false
    Rails.cache.clear
    Upkeep.reset_stats!
    Upkeep::Coercion.reset!
    Upkeep::ActiveRecordStore.wipe!
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

  def surface(name) = Upkeep.registry.lookup(name)

  # The documented strict-mode opt-out, scoped to a block: tests that
  # assert the production warn-and-degrade path run inside it.
  def no_raise
    ENV["UPKEEP_NO_RAISE"] = "1"
    yield
  ensure
    ENV.delete("UPKEEP_NO_RAISE")
  end

  def with_auto_subscribe
    Upkeep::Streams.auto_subscribe = true
    yield
  ensure
    Upkeep::Streams.auto_subscribe = false
  end

  # Simulate a distinct app process: its own store/registry/debouncer
  # instances (sharing the DB and the cable, as real processes would).
  SimProcess = Struct.new(:store, :registry, :debouncer, keyword_init: true)

  def sim_process(window: WINDOW, claimer: Upkeep::DbClaimer.new)
    SimProcess.new(
      store: Upkeep::ActiveRecordStore.new,
      registry: Upkeep::ActiveRecordSurfaceRegistry.new,
      debouncer: Upkeep::Debouncer.new(window: window, claimer: claimer)
    )
  end

  def in_process(sim)
    Upkeep.store = sim.store
    Upkeep.registry = sim.registry
    Upkeep.debouncer = sim.debouncer
    yield
  end

  def visit_board(board)
    get "/boards/#{board.id}"
    assert_response :success
    response.headers["X-Upkeep-Stream"].tap { |s| assert s, "capture should register a cohort" }
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
