# Herd economics: server-side cost of one write to a shared page with N
# subscribed viewers, Tier P (N full re-GETs) vs Tier S (1 scrubbed render +
# N broadcast transmits).
#
# Method notes (honesty):
# - Tier P cost is measured by actually executing N sequential GETs for
#   N = 10 and 100; N = 500 is a linear extrapolation from the measured
#   per-request cost (stated as such in the output).
# - Tier S render+broadcast is measured directly. The per-subscriber
#   transmit is approximated by the pubsub broadcast payload write; real
#   ActionCable adds one websocket write per subscriber, which is not
#   measured here — so the Tier S numbers are a lower bound, and the ratio
#   an upper bound on Tier S advantage at large N.
require_relative "test_helper"
require "benchmark"

class HerdBench < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_herd_economics
    30.times { Card.create!(board: @board1, title: "Seed", status: "open") }
    a = session_for(@alice)
    a.get "/shared_board" # warm template/route caches
    10.times { a.get "/shared_board" }

    # --- Tier P: N full personalized GETs per write ---
    get_ms = {}
    [10, 100].each do |n|
      t = Benchmark.realtime { n.times { a.get "/shared_board" } }
      get_ms[n] = t * 1000
    end
    per_get = get_ms[100] / 100

    # --- Tier S: one scrubbed render + N transmits ---
    descriptor = RefreshSync::Descriptor.new(
      name: "open_cards", partial: "surfaces/cards",
      locals: { cards: Card.where(status: "open") }
    )
    RefreshSync::SharedRender.call(descriptor) # warm
    render_ms = Benchmark.realtime { 10.times { RefreshSync::SharedRender.call(descriptor) } } * 100

    payload = RefreshSync::SharedRender.call(descriptor).html
    transmit_ms = Benchmark.realtime {
      1000.times { ActionCable.server.pubsub.broadcast("herd-bench", payload) }
    } # per-transmit
    ActionCable.server.pubsub.clear
    per_transmit = transmit_ms

    puts "\n== Herd economics: one write to a shared page with N viewers =="
    puts format("per full GET (Tier P unit):        %.3f ms", per_get)
    puts format("one scrubbed render (Tier S base): %.3f ms", render_ms)
    puts format("per broadcast transmit (approx):   %.5f ms", per_transmit)
    puts
    puts format("%-6s %14s %20s %10s", "N", "Tier P (ms)", "Tier S (ms)", "ratio")
    [10, 100, 500].each do |n|
      tier_p = n <= 100 ? get_ms[n] : per_get * n
      tier_s = render_ms + per_transmit * n
      note = n > 100 ? " (extrapolated)" : ""
      puts format("%-6d %11.1f%s %17.2f %12.1fx", n, tier_p, note, tier_s, tier_p / tier_s)
    end
    crossover = (render_ms / (per_get - per_transmit)).ceil
    puts format("\ncrossover: Tier S is cheaper from N = %d viewer(s)", crossover)
    assert true
  end
end
