require_relative "test_helper"

# The origin model: the origin tab is just another subscriber. Writes go
# through POST + head :no_content and the broadcast is the single source of
# UI truth for everyone including the writer. Request-id stamping exists for
# exactly one purpose: a write committed DURING a GET must not re-trigger
# toward the tab whose GET caused it (Turbo 8's client discards refreshes
# whose request-id matches its own request — that discard is native client
# behavior; the server's whole job is the stamp).
class OriginTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def refresh_tags(stream)
    broadcasts(stream).map { |p| ActiveSupport::JSON.decode(p) }
  end

  def request_id_of(tag)
    tag[/request-id="([^"]+)"/, 1]
  end

  # POST write: origin receives the refresh like everyone else, unstamped.
  def test_post_origin_tab_receives_its_own_refresh
    a = session_for(@alice)
    a.get "/boards/#{@board1.id}"
    origin_stream = a.response.headers["X-Upkeep-Stream"]

    a.post "/cards_api", params: { board_id: @board1.id, title: "Mine", status: "open" }
    assert_equal 204, a.response.status

    assert_refreshes(origin_stream, 1)
    tag = refresh_tags(origin_stream).first
    assert_nil request_id_of(tag), "POST-boundary refresh carries no request-id: nobody is suppressed"
  end

  # Write committed during a GET: the broadcast is stamped with that GET's
  # request id (so the origin tab's client can discard it), and other
  # viewers' refreshes still arrive.
  def test_get_committed_write_stamps_the_origin_request_id
    Card.where(status: "read").delete_all
    drain_debounce
    ActionCable.server.pubsub.clear

    b = session_for(@bob)
    b.get "/inbox" # marks card1 read; nobody subscribed yet
    stream_b = b.response.headers["X-Upkeep-Stream"]
    drain_debounce
    ActionCable.server.pubsub.clear

    a = session_for(@alice)
    a.get "/inbox" # marks card2 read — a write during A's GET
    rid_a = a.response.headers["X-Request-Id"]
    stream_a = a.response.headers["X-Upkeep-Stream"]

    assert_refreshes(stream_b, 1)
    assert_equal rid_a, request_id_of(refresh_tags(stream_b).first),
      "refresh is stamped with the originating GET's request id"
    assert_equal 0, broadcasts(stream_a).size,
      "origin's own cohort registered after the write; nothing was addressed to it"
  end

  # Full loop simulation: refresh-triggered GETs also commit writes.
  # Termination comes from Turbo's native request-id discard (simulated
  # client-side, as in the real browser) plus idempotent writes.
  def test_write_on_read_cascade_terminates
    get "/inbox" # consume the open seed cards so both viewers start read
    get "/inbox"
    drain_debounce
    ActionCable.server.pubsub.clear

    clients = [@alice, @bob].map do |user|
      sess = session_for(user)
      sess.get "/inbox"
      { sess: sess,
        stream: sess.response.headers["X-Upkeep-Stream"],
        rid: sess.response.headers["X-Request-Id"],
        seen: 0, refreshes_accepted: 0 }
    end
    drain_debounce
    ActionCable.server.pubsub.clear

    Card.create!(board: @board1, title: "New mail", status: "open") # generation 1

    rounds = 0
    loop do
      raise "cascade did not terminate" if (rounds += 1) > 10
      drain_debounce
      activity = false
      clients.each do |client|
        tags = refresh_tags(client[:stream])
        new_tags = tags[client[:seen]..] || []
        client[:seen] = tags.size
        new_tags.each do |tag|
          rid = request_id_of(tag)
          next if rid && rid == client[:rid] # Turbo's native discard
          activity = true
          client[:refreshes_accepted] += 1
          client[:sess].get "/inbox" # the refresh-triggered GET (may write)
          client[:stream] = client[:sess].response.headers["X-Upkeep-Stream"]
          client[:rid] = client[:sess].response.headers["X-Request-Id"]
          client[:seen] = 0
        end
      end
      break unless activity
    end

    assert_operator rounds, :<=, 3, "cascade must reach a fixed point quickly (took #{rounds} rounds)"
    clients.each do |client|
      assert_operator client[:refreshes_accepted], :>=, 1, "every viewer converged via at least one refresh"
      assert_operator client[:refreshes_accepted], :<=, 2,
        "no viewer accepted more than one refresh per write generation"
    end
    assert_equal 0, Card.where(status: "open").count, "content converged (all mail read)"
  end
end
