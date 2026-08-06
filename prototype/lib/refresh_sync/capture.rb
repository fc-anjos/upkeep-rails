module RefreshSync
  # Controller integration: capture successful HTML GETs, register a cohort,
  # and expose its stream so the page can subscribe with turbo_stream_from.
  # (The real gem injects the stream tag and signs it; a response header is
  # enough for the proof harness.)
  module Capture
    extend ActiveSupport::Concern

    singleton_class.attr_accessor :enabled
    self.enabled = true

    class_methods do
      def refresh_sync(**options)
        around_action :_refresh_sync_capture, **options
      end
    end

    private

    def _refresh_sync_capture
      return yield unless Capture.enabled && request.get?

      recording = Recording.start
      begin
        yield
      ensure
        Recording.finish
      end

      return unless response.successful? && response.media_type == "text/html"

      cohort = RefreshSync.store.register(read_set: recording.read_set)
      response.set_header("X-RefreshSync-Stream", cohort.stream)
    end
  end
end
