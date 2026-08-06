require "digest"

module RefreshSync
  # Scrubbed render for Tier S broadcasts: a named partial with captured
  # locals, rendered by a bare renderer controller on a *fresh thread* —
  # empty session, no cookies, no request, clean thread-locals, clean
  # CurrentAttributes. Never a controller replay, never under any viewer's
  # credentials. Relation locals are reset so the render sees current data.
  #
  # The scrub thread runs its own Recording so instrumented templates yield
  # per-node digests/texts — the region-broadcast payloads and the per-node
  # promotion comparison both come from here.
  module SharedRender
    Result = Struct.new(:html, :digest, :node_digests, :node_texts, keyword_init: true)

    def self.call(descriptor)
      thread = Thread.new do
        Thread.current.name = "refresh_sync_scrub"
        Thread.current.report_on_exception = false # caller handles via #value
        ActiveSupport::CurrentAttributes.clear_all
        begin
          locals = descriptor.locals.transform_values do |value|
            value.is_a?(ActiveRecord::Relation) ? value.reset : value
          end
          recording = Recording.start
          html = RefreshSync.renderer_class.render(partial: descriptor.partial, locals: locals)
          trace = recording.prov
          node_digests = trace.node_digests_since({})
          node_texts = trace.nodes.keys.to_h { |a| [a, trace.text_for(a)] }
          [html, node_digests, node_texts]
        ensure
          Recording.finish
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
      html, node_digests, node_texts = thread.value
      Result.new(
        html: html, digest: Digest::SHA256.hexdigest(html),
        node_digests: node_digests, node_texts: node_texts
      )
    end
  end
end
