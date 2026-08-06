require_relative "test_helper"

# load_async executes the query on a background thread while the capture's
# Recording lives in a thread-local on the request thread — the classic
# misattribution hazard. The read must land in the REQUESTING capture's
# read set (relation recording and instantiation both happen on the
# consuming thread), and the async sql.active_record event must not trip
# the completeness audit into refusing the capture.
class LoadAsyncTest < ActiveSupport::TestCase
  include ProofHelpers

  def test_load_async_reads_land_in_the_capturing_request
    ActiveRecord.async_query_executor = :global_thread_pool
    recording = Upkeep::Recording.start
    relation = Card.where(status: "open").load_async
    sleep 0.05 # let the background execution actually win the race
    titles = relation.map(&:title)
    Upkeep::Recording.finish

    assert_includes titles, "First"
    refute recording.incomplete?,
      "async execution must not read as an unattributable hole: #{recording.incomplete_detail}"
    deps = recording.read_set.tables["cards"]
    assert deps, "async-loaded table missing from the read set"
    hit = deps.predicates.any? { |p| p.key?("status") } || deps.table_reasons.any?
    assert hit, "async-loaded relation left no matchable dependency"
    assert_includes deps.ids, @card1.id
  ensure
    ActiveRecord.async_query_executor = nil
    Upkeep::Recording.finish
  end

  def test_foreign_thread_reads_do_not_pollute_a_capture
    recording = Upkeep::Recording.start
    Thread.new { Board.find(@board2.id) }.join
    Upkeep::Recording.finish
    assert_nil recording.read_set.tables["boards"],
      "a plain background thread's reads belong to nobody's page"
  end
end
