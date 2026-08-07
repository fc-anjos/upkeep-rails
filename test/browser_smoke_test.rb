require_relative "test_helper"
require "net/http"
require "socket"

# The real thing: two actual Chrome browsers against a real Puma server —
# stock Turbo JS, real <turbo-cable-stream-source> subscriptions over a
# real websocket, zero custom JavaScript. Browser A's page performs a
# write (the /inbox write-on-read fixture); browser B's page must update
# by itself via the Tier P refresh.
#
# Skips (with the reason) when Chrome or chromedriver is unavailable or
# their versions disagree — CI installs a matched pair.
class BrowserSmokeTest < ActiveSupport::TestCase
  include ProofHelpers

  CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  TURBO_JS = Gem.find_files("../app/assets/javascripts/turbo.min.js").first ||
             Dir[File.join(Gem.loaded_specs["turbo-rails"].full_gem_path, "app/assets/javascripts/turbo.min.js")].first

  def free_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1].tap { server.close }
  end

  # --- minimal W3C WebDriver client ---------------------------------------

  class Driver
    def initialize(port)
      @port = port
      @pid = Process.spawn("chromedriver", "--port=#{port}", out: IO::NULL, err: IO::NULL)
      deadline = Time.now + 5
      loop do
        Net::HTTP.get(URI("http://127.0.0.1:#{port}/status"))
        break
      rescue StandardError
        raise "chromedriver did not come up" if Time.now > deadline
        sleep 0.05
      end
    end

    def start_session
      body = {
        capabilities: { alwaysMatch: {
          browserName: "chrome",
          "goog:chromeOptions": { binary: CHROME, args: ["--headless=new", "--disable-gpu", "--no-sandbox"] }
        } }
      }
      response = post("/session", body)
      @session = response.dig("value", "sessionId") or
        raise "no session: #{response.dig("value", "message")}"
    end

    def visit(url) = post("/session/#{@session}/url", url: url)

    def source
      get("/session/#{@session}/source").dig("value")
    end

    def quit
      begin
        Net::HTTP.new("127.0.0.1", @port).delete("/session/#{@session}") if @session
      rescue StandardError
        nil
      end
      begin
        Process.kill("TERM", @pid)
        Process.wait(@pid)
      rescue StandardError
        nil
      end
    end

    private

    def post(path, body)
      http = Net::HTTP.new("127.0.0.1", @port)
      http.read_timeout = 60
      JSON.parse(http.post(path, JSON.generate(body), "Content-Type" => "application/json").body)
    end

    def get(path)
      JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{@port}#{path}")))
    end
  end

  # Serve ProofApp for real, with Turbo JS injected into every HTML page
  # (the test fixtures render bare HTML; a real app's layout already loads
  # turbo-rails). Single Puma process, async cable — in-process delivery.
  def spawn_server(port)
    turbo_js = TURBO_JS
    fork do
      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3", database: File.join(PROTO_ROOT, "tmp", "proof.sqlite3"),
        timeout: 2000
      )
      ActionCable.server.config.cable = { "adapter" => "async" }
      ActionCable.server.instance_variable_set(:@pubsub, nil)
      Upkeep.store = Upkeep::ActiveRecordStore.new
      Upkeep.registry = Upkeep::ActiveRecordSurfaceRegistry.new
      Upkeep.debouncer = Upkeep::Debouncer.new(window: 0.2)
      # The browsers subscribe through injected tags; /inbox renders a
      # real <body>, so injection is sound here.
      Upkeep::Streams.auto_subscribe = true

      injector = Class.new do
        define_method(:initialize) { |app| @app = app }
        define_method(:call) do |env|
          if env["PATH_INFO"] == "/turbo.min.js"
            [200, { "content-type" => "text/javascript" }, [File.read(turbo_js)]]
          else
            status, headers, body = @app.call(env)
            type = headers["content-type"] || headers["Content-Type"]
            if type.to_s.include?("text/html")
              html = +""
              body.each { |part| html << part }
              body.close if body.respond_to?(:close)
              tag = %(<script type="module">import "/turbo.min.js";</script>)
              html.include?("</body>") ? html.sub!("</body>", "#{tag}</body>") : html << tag
              headers = headers.merge("content-length" => html.bytesize.to_s)
              body = [html]
            end
            [status, headers, body]
          end
        end
      end

      require "puma"
      require "puma/configuration"
      require "puma/log_writer"
      app = injector.new(ProofApp)
      conf = Puma::Configuration.new do |c|
        c.app app
        c.bind "tcp://127.0.0.1:#{port}"
        c.threads 1, 4
        c.environment "test"
      end
      Puma::Launcher.new(conf, log_writer: Puma::LogWriter.null).run
    end
  end

  def wait_for_server(port)
    deadline = Time.now + 15
    begin
      Net::HTTP.get(URI("http://127.0.0.1:#{port}/cards"))
    rescue StandardError
      raise "app server did not come up" if Time.now > deadline
      sleep 0.1
      retry
    end
  end

  def test_write_in_one_browser_updates_the_other
    skip "chromedriver not installed" unless system("which chromedriver > /dev/null 2>&1")
    skip "Chrome not installed" unless File.exist?(CHROME)
    skip "turbo.min.js not found in the turbo-rails gem" unless TURBO_JS

    app_port = free_port
    server_pid = spawn_server(app_port)
    wait_for_server(app_port)

    begin
      begin
        browser_b = Driver.new(free_port)
        browser_a = Driver.new(free_port)
        browser_b.start_session
        browser_a.start_session
      rescue StandardError => e
        skip "browser automation unavailable (quarantined chromedriver, version mismatch, ...): #{e.message}"
      end

      # B opens the inbox: its GET marks card1 read and registers a cohort.
      browser_b.visit("http://127.0.0.1:#{app_port}/inbox")
      deadline = Time.now + 10
      sleep 0.1 until browser_b.source.include?("First:read") || Time.now > deadline
      assert_includes browser_b.source, "First:read"
      assert_includes browser_b.source, "Other:open"
      assert_includes browser_b.source, "turbo-cable-stream-source",
        "B's page must carry the injected stream sources"

      # A's visit writes: card2 flips to read. B does nothing.
      browser_a.visit("http://127.0.0.1:#{app_port}/inbox")

      # B's page must update itself — a real websocket delivery, a real
      # Turbo refresh, no custom client code.
      deadline = Time.now + 15
      sleep 0.2 until browser_b.source.include?("Other:read") || Time.now > deadline
      assert_includes browser_b.source, "Other:read",
        "browser B never received the refresh for browser A's write"
    ensure
      browser_a&.quit
      browser_b&.quit
      begin
        Process.kill("TERM", server_pid)
        Process.wait(server_pid)
      rescue StandardError
        nil
      end
    end
  end
end
