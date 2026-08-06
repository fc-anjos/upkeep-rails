require_relative "test_helper"
require "redis"

# The multi-process reality check: real OS processes (fork), the shared
# SQLite store, and a REAL cable adapter (redis pub/sub — the actual
# ActionCable redis subscription path, not the test adapter). Skipped when
# no redis server answers.
#
# Proves: a write handled in process A reaches a subscriber connected in
# process B; two processes reporting the same write coalesce to ONE
# delivery via DB claims; a member ejection persisted in one process is
# visible in another.
class CrossProcessTest < ActiveSupport::TestCase
  include ProofHelpers

  def redis_available?
    Redis.new(timeout: 0.5).ping == "PONG"
  rescue StandardError
    false
  end

  def subscribe_collecting(stream)
    messages = []
    ready = Queue.new
    thread = Thread.new do
      Redis.new.subscribe(stream) do |on|
        on.subscribe { ready << true }
        on.message { |_ch, msg| messages << msg }
      end
    rescue StandardError
      nil
    end
    ready.pop
    [messages, thread]
  end

  # A forked worker: fresh DB connection, real redis cable, its own
  # store/debouncer/claimer instances — a faithful second app process.
  def fork_worker(&block)
    fork do
      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3", database: File.join(PROTO_ROOT, "tmp", "proof.sqlite3"),
        timeout: 2000 # multi-process SQLite: wait out the writer instead of BusyException
      )
      ActionCable.server.config.cable = { "adapter" => "redis" }
      ActionCable.server.instance_variable_set(:@pubsub, nil)
      Upkeep.store = Upkeep::ActiveRecordStore.new
      Upkeep.registry = Upkeep::ActiveRecordSurfaceRegistry.new
      Upkeep.debouncer = Upkeep::Debouncer.new(window: 0.2, claimer: Upkeep::DbClaimer.new)
      block.call
      sleep 0.8 # let the debounce window fire before the process exits
      exit!(0)
    end
  end

  def test_write_in_one_process_reaches_a_subscriber_of_another
    skip "no redis server" unless redis_available?

    # Process "browser-owner": register the cohort into the shared store.
    rs = Upkeep::ReadSet.new
    rs.record_id("cards", @card1.id)
    ar_store = Upkeep::ActiveRecordStore.new
    cohort = ar_store.register(read_set: rs)
    messages, thread = subscribe_collecting(cohort.stream)

    # Process "writer": a real forked process reports the write.
    pid = fork_worker do
      Upkeep.report_change(
        Upkeep::Change.new(table: "cards", id: @card1.id, kind: :update,
                                new_attrs: { "id" => @card1.id, "title" => "From another process" })
      )
    end
    Process.wait(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    sleep 0.05 while messages.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

    assert_equal 1, messages.size, "the refresh must cross process boundaries via the real cable"
    assert_includes ActiveSupport::JSON.decode(messages.first), %(action="refresh")
  ensure
    thread&.kill
  end

  def test_same_write_reported_by_two_processes_delivers_once
    skip "no redis server" unless redis_available?

    rs = Upkeep::ReadSet.new
    rs.record_id("cards", @card1.id)
    cohort = Upkeep::ActiveRecordStore.new.register(read_set: rs)
    messages, thread = subscribe_collecting(cohort.stream)

    change = Upkeep::Change.new(table: "cards", id: @card1.id, kind: :update,
                                     new_attrs: { "id" => @card1.id, "title" => "Twice" })
    pids = 2.times.map { fork_worker { Upkeep.report_change(change) } }
    pids.each { |p| Process.wait(p) }
    sleep 1.0

    assert_equal 1, messages.size,
      "two processes coalescing on the same debounce window must deliver exactly once"
  ensure
    thread&.kill
  end

  def test_ejection_in_one_process_is_visible_in_another
    registry = Upkeep::ActiveRecordSurfaceRegistry.new
    seeded = registry.upsert("xproc")
    seeded.instance_variable_set(:@status, :shared)
    seeded.instance_variable_set(:@shared_read_set, Upkeep::ReadSet.new)
    seeded.persist!

    pid = fork do
      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3", database: File.join(PROTO_ROOT, "tmp", "proof.sqlite3"),
        timeout: 2000 # multi-process SQLite: wait out the writer instead of BusyException
      )
      Upkeep::ActiveRecordSurfaceRegistry.new.lookup("xproc")
                 .eject_member!("42", reason: :delta_row_write)
      exit!(0)
    end
    Process.wait(pid)
    assert_equal 0, $?.exitstatus
    assert registry.lookup("xproc").member_diverged?("42"),
      "an ejection persisted by another OS process must hydrate here"
  end
end
