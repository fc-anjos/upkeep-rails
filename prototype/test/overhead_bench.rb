# Rough capture-overhead measurement: same action with and without capture.
require_relative "test_helper"
require "benchmark"

class PlainBoardsController < ActionController::Base
  def show
    @board = Board.find(params[:id])
    @cards = @board.cards.where(status: "open").to_a
    render inline: <<~ERB, layout: false
      <h1><%= @board.name %></h1>
      <ul><% @cards.each do |card| %><li><%= card.title %></li><% end %></ul>
    ERB
  end
end

Rails.application.routes.append do
  get "/plain_boards/:id", to: "plain_boards#show"
end
Rails.application.reload_routes!

class OverheadBench < ActionDispatch::IntegrationTest
  include ProofHelpers

  N = 300

  def test_capture_overhead
    50.times { get "/plain_boards/#{@board1.id}"; get "/boards/#{@board1.id}" } # warm

    plain = 0.0
    captured = 0.0
    6.times do |i|
      first_captured = i.odd?
      RefreshSync::Capture.enabled = first_captured
      t1 = Benchmark.realtime { (N / 6).times { get "/boards/#{@board1.id}" } }
      RefreshSync::Capture.enabled = !first_captured
      RefreshSync.store = RefreshSync::MemoryStore.new
      t2 = Benchmark.realtime { (N / 6).times { get "/boards/#{@board1.id}" } }
      captured += first_captured ? t1 : t2
      plain += first_captured ? t2 : t1
    end

    puts format("\nplain:    %.3f ms/req", plain / N * 1000)
    puts format("captured: %.3f ms/req", captured / N * 1000)
    puts format("overhead: %.3f ms/req (%.1f%%)", (captured - plain) / N * 1000, (captured / plain - 1) * 100)
    assert true
  end
end
