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
    t.string :title
    t.string :status, default: "open"
  end
end

RefreshSync.install!

class Board < ActiveRecord::Base
  has_many :cards
end

class Card < ActiveRecord::Base
  belongs_to :board
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
end

Rails.application.routes.draw do
  get "/boards/:id", to: "boards#show"
  get "/cards", to: "boards#all_cards"
end

module ProofHelpers
  WINDOW = 0.3

  def setup
    RefreshSync.store = RefreshSync::MemoryStore.new
    RefreshSync.debouncer = RefreshSync::Debouncer.new(window: WINDOW)
    RefreshSync.reset_stats!
    ActionCable.server.pubsub.clear
    Board.delete_all
    Card.delete_all
    @board1 = Board.create!(name: "Board One")
    @board2 = Board.create!(name: "Board Two")
    @card1 = Card.create!(board: @board1, title: "First", status: "open")
    @card2 = Card.create!(board: @board2, title: "Other", status: "open")
  end

  def broadcasts(stream)
    ActionCable.server.pubsub.broadcasts(stream)
  end

  def visit_board(board)
    get "/boards/#{board.id}"
    assert_response :success
    response.headers["X-RefreshSync-Stream"].tap { |s| assert s, "capture should register a cohort" }
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
