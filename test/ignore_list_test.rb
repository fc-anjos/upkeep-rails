require_relative "test_helper"

# Infrastructure tables produce no change events; misuse (an active cohort
# depending on an ignored table) warns loudly instead of failing silently.
class IgnoreListTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def test_ignored_table_writes_produce_no_events_and_no_analysis
    visit_board(@board1)
    baseline = RefreshSync.stats[:writes_analyzed]

    SessionRecord.create!(session_id: "abc", data: "payload")
    AuditRecord.create!(action: "card.update")
    drain_debounce

    assert_equal baseline, RefreshSync.stats[:writes_analyzed],
      "ignored-table writes must not be analyzed"
    assert_equal 0, RefreshSync.stats[:ignored_writes_warned],
      "no cohort watches sessions/audits here — no warning either"
  end

  def test_ignored_write_on_a_watched_table_warns_loudly_and_still_skips
    sess = session_for(@alice)
    sess.get "/audit_log" # this cohort genuinely reads the audits table
    stream = sess.response.headers["X-RefreshSync-Stream"]

    events = []
    callback = ->(*, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(callback, "ignored_table_write_skipped.refresh_sync") do
      AuditRecord.create!(action: "board.rename")
      drain_debounce
    end

    assert_equal 1, events.size, "misuse detector must fire"
    assert_equal "audits", events.first[:table]
    assert_operator RefreshSync.stats[:ignored_writes_warned], :>=, 1
    assert_equal 0, broadcasts(stream).size,
      "the write is still skipped (documented degradation, loudly)"
  end

  def test_ignore_list_is_app_extensible
    RefreshSync.ignored_tables << "boards"
    visit_board(@board1)
    stream = response.headers["X-RefreshSync-Stream"]

    @board1.update!(name: "Renamed")
    assert_no_refresh(stream)
  ensure
    RefreshSync.ignored_tables = nil
  end
end
