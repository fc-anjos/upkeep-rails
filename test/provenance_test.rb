require_relative "test_helper"

# Stage 1 of the provenance port: read-set entries carry template node
# addresses as pure metadata, and two viewers' traces localize divergence to
# the exact personal nodes.
class ProvenanceTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_read_set_entries_carry_node_addresses
    session_for(@alice).get "/vip"
    read_set = RefreshSync::Capture.last_recording.read_set

    node_reads = read_set.tables.fetch("cards").node_reads
    assert node_reads.any?, "cards reads should carry node addresses"
    address, deps = node_reads.find { |_a, d| d.ids.any? }
    assert address.start_with?("t:"), "structural address expected, got #{address.inspect}"
    assert_includes deps.ids, @card1.id, "the loop node should own the loaded card ids"

    # Round-trips through JSON (the AR store path) intact.
    reloaded = RefreshSync::ReadSet.from_h(JSON.parse(JSON.generate(read_set.to_h)))
    assert_equal read_set.to_h, reloaded.to_h
    assert reloaded.tables.fetch("cards").node_reads.key?(address)
  end

  def test_matching_node_addresses_routes_a_change_to_its_nodes
    session_for(@alice).get "/vip"
    read_set = RefreshSync::Capture.last_recording.read_set

    change = RefreshSync::Change.new(
      table: "cards", id: @card1.id, kind: :update,
      old_attrs: @card1.attributes, new_attrs: @card1.attributes
    )
    matched = read_set.matching_node_addresses(change)
    assert matched.any?, "the change should map to at least one node"
    matched.each { |address| assert address.start_with?("t:") }

    boards_change = RefreshSync::Change.new(
      table: "boards", id: @board1.id, kind: :update,
      old_attrs: @board1.attributes, new_attrs: @board1.attributes
    )
    assert_equal [], read_set.matching_node_addresses(boards_change),
      "no template node read boards on this page"
  end

  def test_divergence_localizes_to_the_admin_badge_node
    session_for(@alice).get "/badge"
    trace_a = RefreshSync::Capture.last_recording.prov
    session_for(@carol).get "/badge" # carol is admin: badge div renders
    trace_c = RefreshSync::Capture.last_recording.prov

    result = RefreshSync::Provenance.localize(trace_a, trace_c)

    assert result[:differing].any?, "admin badge must diverge"
    assert_equal 1, result[:innermost].size,
      "divergence should localize to one innermost node, got #{result[:innermost].inspect}"
    island = result[:innermost].first
    assert_includes trace_c.text_for(island), "ADMIN TOOLS"

    list_address = trace_c.nodes.keys.find { |a| trace_c.text_for(a).to_s.start_with?("<ul") }
    assert list_address, "the card list node should be traced"
    assert_includes result[:shared], list_address, "the card list is byte-shared"
  end
end
