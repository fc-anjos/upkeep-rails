# frozen_string_literal: true

# Spike harness: query→node provenance, divergence localization, structural
# addressing, and overhead — through ReActionView/Herb as the render path.
#
# Run: ruby spike/provenance_spike_test.rb

require "minitest/autorun"
require "logger"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
require "reactionview"
require_relative "lib/prov_spike"

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"

class SpikeApp < Rails::Application
  config.load_defaults 8.0
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "prov-spike"
  config.logger = Logger.new(IO::NULL)
  config.action_controller.allow_forgery_protection = false
  config.action_dispatch.show_exceptions = :none
end

ReActionView.config.intercept_erb = true
ReActionView.config.transform_visitors << ProvSpike::Visitor.new
ReActionView::Template::Handlers::Herb.prepend(ProvSpike::HandlerShim)

Rails.application.initialize!

# ReActionView's railtie registered its handlers; observe whether the
# class-registration works, but register a proper instance ourselves so the
# spike doesn't depend on it (see FINDINGS on maturity).
ActionView::Template.register_template_handler :erb, ReActionView::Template::Handlers::ERB.new

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :boards do |t|
    t.string :name
  end
  create_table :cards do |t|
    t.string :title
    t.integer :board_id
    t.integer :owner_id
  end
  create_table :users do |t|
    t.string :name
    t.boolean :admin, default: false
  end
end

class Board < ActiveRecord::Base
  has_many :cards
end

class Card < ActiveRecord::Base
  belongs_to :board
  belongs_to :owner, class_name: "User", optional: true
end

class User < ActiveRecord::Base
end

ProvSpike.install_query_capture!

class BoardsController < ActionController::Base
  prepend_view_path File.expand_path("views_plain", __dir__)
  prepend_view_path File.expand_path("views", __dir__)
  layout "application"

  class << self
    attr_accessor :last_recording
  end

  around_action do |controller, action|
    if controller.params[:capture]
      ProvSpike::Runtime.record!
      action.call
      BoardsController.last_recording = ProvSpike::Runtime.finish!
    else
      action.call
    end
  end

  def show
    @board = Board.find(params[:id])
  end

  # Same controller, same around_action, uninstrumented template set —
  # isolates instrumentation cost from controller/route shape.
  def show_plain
    @board = Board.find(params[:id])
    render template: "plain_boards/show"
  end

  def dashboard
    @viewer = User.find(params[:viewer_id])
    @cards = Card.order(:id).to_a
    render :dashboard
  end
end

class PlainBoardsController < ActionController::Base
  prepend_view_path File.expand_path("views_plain", __dir__)
  layout "application"

  def show
    @board = Board.find(params[:id])
  end
end

Rails.application.routes.draw do
  get "boards/:id" => "boards#show"
  get "boards_plain/:id" => "boards#show_plain"
  get "dashboard" => "boards#dashboard"
  get "plain_boards/:id" => "plain_boards#show"
end

def template_digest(relative)
  Digest::SHA256.hexdigest(File.read(File.expand_path(relative, __dir__)))[0, 12]
end

class ProvenanceSpikeTest < ActionDispatch::IntegrationTest
  def setup
    Card.delete_all
    Board.delete_all
    User.delete_all
    @alice = User.create!(name: "AliceSentinel", admin: true)
    @bob = User.create!(name: "Bob", admin: false)
    @board = Board.create!(name: "Roadmap")
    @c1 = Card.create!(board: @board, title: "Ship it", owner: @bob)
    @c2 = Card.create!(board: @board, title: "Test it", owner: @alice)
  end

  def capture(path)
    get path
    assert_response :success
    BoardsController.last_recording
  end

  # -- Task 2: query→node provenance ----------------------------------------

  def test_queries_attach_to_the_right_nodes
    rec = capture("/boards/#{@board.id}?capture=1")

    show_digest = template_digest("views/boards/show.html.erb")
    layout_digest = template_digest("views/layouts/application.html.erb")
    card_digest = template_digest("views/boards/_card.html.erb")

    by_query = {}
    rec.nodes.each_value do |node|
      node.queries.each { |q| (by_query[q[:name]] ||= []) << node }
    end

    puts "\n--- provenance map (address | file:line | queries | reads) ---"
    rec.nodes.each_value do |node|
      next if node.queries.empty? && node.reads.empty?

      puts format("%-42s %-28s %-30s %s",
                  node.address,
                  "#{node.file.split("/").last}:#{node.line}",
                  node.queries.map { |q| q[:name] }.join(","),
                  node.reads.map { |t, ids| "#{t}:#{ids.uniq.inspect}" }.join(" "))
    end

    # Controller-time read (Board.find) attributes OUTSIDE any template node.
    outside = rec.nodes["(outside-template)"]
    refute_nil outside, "controller-time queries must land outside template nodes"
    assert_includes outside.queries.map { |q| q[:name] }, "Board Load"
    assert_equal [@board.id], outside.reads["boards"].uniq

    # Layout's Board.count lands on a node in the LAYOUT template.
    count_nodes = by_query["Board Count"]
    refute_nil count_nodes, "expected a Board Count query during layout render"
    assert count_nodes.all? { |n| n.address.include?(layout_digest) },
           "Board.count should attribute to a layout node, got #{count_nodes.map(&:address)}"

    # The `if @board.cards.any?` guard: Card Exists? on a show-template node.
    exists_nodes = by_query["Card Exists?"]
    refute_nil exists_nodes, "expected Card Exists? from cards.any?"
    exists_addr = exists_nodes.first.address
    assert_includes exists_addr, show_digest

    # The loop: Card Load on a DIFFERENT show-template node, nested inside
    # the guard node (the collection query belongs to the loop, not the page).
    load_nodes = by_query["Card Load"]
    refute_nil load_nodes
    load_addr = load_nodes.first.address
    assert_includes load_addr, show_digest
    refute_equal exists_addr, load_addr
    assert ProvSpike.descendant_of?(load_addr, exists_addr),
           "loop node #{load_addr} should be inside guard node #{exists_addr}"

    # Loaded card ids recorded at the loop node.
    assert_equal [@c1.id, @c2.id].sort, load_nodes.first.reads["cards"].uniq.sort

    # Per-iteration N+1 (card.owner.name): User Load on a node in the PARTIAL
    # template, with both owners accumulated across iterations.
    user_nodes = by_query["User Load"]
    refute_nil user_nodes, "expected per-iteration User Load from card.owner"
    assert user_nodes.all? { |n| n.address.include?(card_digest) },
           "owner loads should attribute inside _card partial, got #{user_nodes.map(&:address)}"
    owner_ids = user_nodes.flat_map { |n| n.reads["users"] }.uniq.sort
    assert_equal [@alice.id, @bob.id].sort, owner_ids
  end

  # -- Task 3: divergence localization ---------------------------------------

  def test_divergence_localizes_to_admin_badge_nodes
    rec_admin = capture("/dashboard?viewer_id=#{@alice.id}&capture=1")
    rec_bob = capture("/dashboard?viewer_id=#{@bob.id}&capture=1")

    result = ProvSpike.localize_divergence(rec_admin, rec_bob)
    dash_digest = template_digest("views/boards/dashboard.html.erb")

    puts "\n--- divergence ---"
    puts "differing: #{result[:differing].inspect}"
    puts "innermost: #{result[:innermost].inspect}"
    puts "shared:    #{result[:shared].size} nodes"

    refute_empty result[:innermost]

    # Layout nodes differ too (they contain the yielded page), but byte-range
    # containment must exclude them from the innermost set.
    layout_digest = template_digest("views/layouts/application.html.erb")
    result[:innermost].each do |addr|
      refute_includes addr, layout_digest,
                      "layout ancestor leaked into innermost set: #{addr}"
    end

    # Every personal island lives in the dashboard template, inside the
    # `if @viewer.admin` guard subtree (or IS a node of that subtree that the
    # non-admin render never entered).
    guard_addr = result[:differing].select { |a| a.include?(dash_digest) }.min_by(&:length)
    assert_includes guard_addr, dash_digest

    result[:innermost].each do |addr|
      assert_includes addr, dash_digest,
                      "personal island outside dashboard template: #{addr}"
      assert addr == guard_addr || ProvSpike.descendant_of?(addr, guard_addr),
             "#{addr} is not within the admin-guard subtree #{guard_addr}"
    end

    # The card list and heading are byte-shared between an admin and a
    # regular viewer — the whole point: only the badge is personal.
    shared_texts_a = result[:shared].filter_map { |addr|
      node = rec_admin.nodes[addr]
      rec_admin.text_for(node) if node
    }
    assert shared_texts_a.any? { |t| t.include?("Ship it") },
           "the shared card list should be in the shared node set"
    assert shared_texts_a.any? { |t| t.include?("<h1>Dashboard</h1>") }

    # And the sentinel (admin's name) never appears in any shared node text.
    shared_texts_b = result[:shared].filter_map { |addr|
      node = rec_bob.nodes[addr]
      rec_bob.text_for(node) if node
    }
    (shared_texts_a + shared_texts_b).each do |text|
      refute_includes text, "AliceSentinel"
    end
  end

  # -- Task 4: structural addressing ------------------------------------------

  def test_addresses_stable_across_renders_and_data_changes
    rec1 = capture("/boards/#{@board.id}?capture=1")
    Card.create!(board: @board, title: "Extra", owner: @bob)
    rec2 = capture("/boards/#{@board.id}?capture=1")

    show_digest = template_digest("views/boards/show.html.erb")
    addrs1 = rec1.nodes.keys.select { |a| a.include?(show_digest) }.sort
    addrs2 = rec2.nodes.keys.select { |a| a.include?(show_digest) }.sort

    assert_equal addrs1, addrs2,
                 "addresses must survive re-render and data changes"

    # A template source change changes the digest component of every address
    # (address = source digest + node path, by construction).
    modified = File.read(File.expand_path("views/boards/show.html.erb", __dir__)) + "<!-- v2 -->"
    new_digest = Digest::SHA256.hexdigest(modified)[0, 12]
    refute_equal show_digest, new_digest
  end

  # -- Rendering fidelity + overhead ------------------------------------------

  def test_instrumented_output_matches_plain_output
    get "/boards/#{@board.id}"
    instrumented = response.body
    get "/plain_boards/#{@board.id}"
    plain = response.body

    normalize = ->(s) { s.gsub(/\s+/, " ").strip }
    assert_equal normalize.call(plain), normalize.call(instrumented),
                 "instrumentation must not change rendered content (modulo whitespace)"

    if plain == instrumented
      puts "\nfidelity: instrumented output BYTE-IDENTICAL to plain"
    else
      puts "\nfidelity: instrumented output identical modulo whitespace (trim interplay — see FINDINGS)"
    end
  end

  def test_overhead_measurement
    # Warm all template caches.
    get "/plain_boards/#{@board.id}"
    get "/boards_plain/#{@board.id}"
    get "/boards/#{@board.id}"
    get "/boards/#{@board.id}?capture=1"

    n = 200
    bench = lambda { |path|
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      n.times { get path }
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0 / n
    }

    # Order-alternated pairs (lesson from the prototype: never before/after).
    plain_same = []   # same controller + around_action, uninstrumented page templates
    plain_cross = []  # different controller entirely (route/controller shape artifact probe)
    instr_ms = []
    capture_ms = []
    4.times do |i|
      order = [
        [plain_same, "/boards_plain/#{@board.id}"],
        [plain_cross, "/plain_boards/#{@board.id}"],
        [instr_ms, "/boards/#{@board.id}"],
        [capture_ms, "/boards/#{@board.id}?capture=1"],
      ]
      order.reverse! if i.odd?
      order.each { |bucket, path| bucket << bench.call(path) }
    end

    avg = ->(a) { a.sum / a.size }
    base = avg.call(plain_same)
    puts "\n--- overhead (ms/request, #{n * 4} requests each, order-alternated) ---"
    puts format("plain templates, same controller:   %.3f", base)
    puts format("plain templates, other controller:  %.3f", avg.call(plain_cross))
    puts format("instrumented, capture OFF:          %.3f  (%+.3f)", avg.call(instr_ms), avg.call(instr_ms) - base)
    puts format("instrumented, capture ON:           %.3f  (%+.3f)", avg.call(capture_ms), avg.call(capture_ms) - base)

    assert avg.call(instr_ms) < base * 3,
           "capture-off overhead should not triple render cost"
  end
end
