require_relative "test_helper"

# Cohorts register only for genuine browser HTML requests. Write capture
# stays global — only registration is guarded.
class ActivationGuardTest < ActionDispatch::IntegrationTest
  include ProofHelpers

  def cohort_count
    RefreshSync.store.matching_cohorts(
      RefreshSync::Change.new(table: "cards", kind: :table)
    ).size
  end

  def test_normal_browser_get_registers
    visit_board(@board1)
    assert response.headers["X-RefreshSync-Stream"]
  end

  def test_job_driven_integration_session_registers_nothing
    sess = open_session
    sess.post "/login", params: { user_id: @alice.id }
    before = cohort_count

    SidekiqStyleJob.perform_now(sess, "/boards/#{@board1.id}")

    assert_equal 200, sess.response.status, "the job's request itself succeeds"
    assert_nil sess.response.headers["X-RefreshSync-Stream"],
      "job-context requests must not register cohorts"
    assert_equal before, cohort_count
  end

  def test_non_html_and_xhr_requests_register_nothing
    get "/boards/#{@board1.id}", headers: { "Accept" => "application/x-llm" }
    assert_nil response.headers["X-RefreshSync-Stream"],
      "chatbot-format requests must not register cohorts"

    get "/boards/#{@board1.id}", xhr: true
    assert_nil response.headers["X-RefreshSync-Stream"],
      "XHR requests must not register cohorts"
  end

  def test_writes_from_suppressed_contexts_still_update_subscribed_pages
    stream = visit_board(@board1)

    RefreshSync.suppress_registration do
      @card1.update!(title: "Written from a job")
    end
    assert_refreshes(stream, 1)
  end
end
