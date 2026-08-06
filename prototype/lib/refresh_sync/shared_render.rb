require "digest"

module RefreshSync
  # Scrubbed render for Tier S broadcasts: a named partial with captured
  # locals, rendered by a bare renderer controller on a *fresh thread* —
  # empty session, no cookies, no request, clean thread-locals, clean
  # CurrentAttributes. Never a controller replay, never under any viewer's
  # credentials. Relation locals are reset so the render sees current data.
  module SharedRender
    Result = Struct.new(:html, :digest, keyword_init: true)

    def self.call(descriptor)
      thread = Thread.new do
        Thread.current.name = "refresh_sync_scrub"
        Thread.current.report_on_exception = false # caller handles via #value
        ActiveSupport::CurrentAttributes.clear_all
        begin
          locals = descriptor.locals.transform_values do |value|
            value.is_a?(ActiveRecord::Relation) ? value.reset : value
          end
          RefreshSync.renderer_class.render(partial: descriptor.partial, locals: locals)
        ensure
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
      html = thread.value
      Result.new(html: html, digest: Digest::SHA256.hexdigest(html))
    end
  end
end
