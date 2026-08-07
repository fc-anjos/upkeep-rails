require_relative "test_helper"

# The per-request dev summary: after each captured HTML request, one line
# through the Rails logger saying whether the page is live, what it
# registered, and every degradation with its reason and source hint.
# Development only — outside development nothing is collected or logged.
class DevSummaryTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  class CollectingLogger
    attr_reader :lines

    def initialize = @lines = []
    def info(msg) = @lines << msg
  end

  def setup
    super
    @logger = CollectingLogger.new
    Upkeep::Legibility.logger = @logger
  end

  def teardown
    Upkeep::Legibility.env = nil
    Upkeep::Legibility.logger = nil
  end

  def in_development
    Upkeep::Legibility.env = "development"
    yield
  ensure
    Upkeep::Legibility.env = nil
  end

  def summary_lines = @logger.lines.grep(/\A\[upkeep\]/)

  def test_no_summary_outside_development
    get "/boards/#{@board1.id}"
    assert_response :success
    assert_empty summary_lines
  end

  def test_live_request_logs_one_truthful_line
    # Warm the template cache outside the summarized request: one-time
    # compile degradations (the pulse layout fails Herb compilation and
    # falls back to stock ERB — truthfully reported when it happens)
    # belong to the process's first render, not to this page.
    get "/pulse/board"

    in_development { get "/pulse/board" }

    assert_equal 1, summary_lines.size
    line = summary_lines.first
    assert_match(/\A\[upkeep\] live · GET \/pulse\/board · \d+ cohorts?\b/, line)
    assert_match(/1 candidate surface/, line)
    refute_match(/degraded/, line, "nothing degraded on this page: #{line}")
  end

  def test_table_level_degradation_carries_reason_and_source_hint
    in_development { get "/opaque_cards" }

    line = summary_lines.first
    assert line, "captured request must log a summary"
    assert_match(/\[upkeep\] live/, line)
    assert_match(%r{degraded: cards → table-level \(unanalyzable_grouping at test/test_helper\.rb:\d+\)}, line)
  end

  # The census win: a plain raw-SQL fragment parses into a structured
  # predicate — nothing degrades anymore.
  def test_plain_fragment_no_longer_degrades
    in_development { get "/fragment_cards" }

    line = summary_lines.first
    assert_match(/\[upkeep\] live/, line)
    refute_match(/degraded/, line, "a parseable fragment must not degrade: #{line}")
  end

  def test_unhooked_read_degradation_names_the_query
    in_development { get "/doors/raw_named" }

    line = summary_lines.first
    assert_match(/degraded: cards → table-level \(unhooked_read_door/, line)
  end

  def test_pinned_surface_shows_in_the_summary
    sess = session_for(@alice)
    in_development { sess.get "/dashboard" }

    line = summary_lines.first
    assert_match(/1 pinned surface/, line)
    assert_match(/surface my_cards pinned \(identity_predicate\)/, line)
  end

  def test_refused_capture_says_not_live_and_why
    in_development do
      no_raise { get "/doors/raw_scalar" }
    end

    line = summary_lines.first
    assert_match(/\A\[upkeep\] NOT live · GET \/doors\/raw_scalar/, line)
    assert_match(/capture refused/, line)
    assert_match(/unattributable/, line)
    assert_match(/no cohort/, line)
  end

  # The parser now attributes an anonymous raw read to its tables: the
  # page stays LIVE, coarsened to table-level — no longer a refusal.
  def test_parser_attributed_raw_read_stays_live_coarsened
    in_development { get "/doors/raw_anonymous" }

    line = summary_lines.first
    assert_match(/\A\[upkeep\] live · GET \/doors\/raw_anonymous/, line)
    assert_match(/degraded: cards → table-level \(unattributed_query/, line)
  end

  def test_promoted_surface_counts_as_promoted
    a = session_for(@alice)
    c = session_for(@carol)
    a.get "/shared_board"
    c.get "/shared_board"
    assert_equal :shared, surface("open_cards").status

    in_development { session_for(@alice).get "/shared_board" }
    assert_match(/1 promoted surface/, summary_lines.first)
  end
end
