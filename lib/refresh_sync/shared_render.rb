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
    # read_set: everything the scrubbed render itself read — the evidence
    # base for per-member divergence (a write matching a member's read set
    # but NOT this one changed something only that member depends on).
    Result = Struct.new(:html, :digest, :node_digests, :node_texts, :read_set, keyword_init: true)

    # The scrub renderer knows the app's view helpers (app/helpers modules,
    # derived from the framework's own aggregate — Rails.application.helpers)
    # but deliberately NOT helper_method controller delegations: those reach
    # into controller/session state, which the scrub contract forbids. The
    # base class stays bare ActionController::Base — never the app's
    # ApplicationController.
    def self.renderer
      base = RefreshSync.renderer_class
      return @renderer if @renderer && @renderer_base == base
      @renderer_base = base
      @renderer =
        if defined?(::Rails) && ::Rails.respond_to?(:application) &&
           ::Rails.application.respond_to?(:helpers)
          helpers = ::Rails.application.helpers
          Class.new(base) do
            define_singleton_method(:name) { "RefreshSync::ScrubRenderer" }
            helper helpers
          end
        else
          base
        end
    end

    def self.reset_renderer! = @renderer = @renderer_base = nil

    def self.call(descriptor)
      thread = Thread.new do
        Thread.current.name = "refresh_sync_scrub"
        Thread.current.report_on_exception = false # caller handles via #value
        ActiveSupport::CurrentAttributes.clear_all
        begin
          locals = descriptor.locals.transform_values do |value|
            if value.is_a?(ActiveRecord::Relation)
              value.reset
            elsif descriptor.record_array?(value)
              # Captured record objects hold captured attribute values; the
              # scrub render must see current data — refetch by id, order
              # preserved (page composition stays as captured).
              klass = value.first.class
              ids = value.map(&:id)
              klass.where(id: ids).in_order_of(:id, ids).to_a
            else
              value
            end
          end
          recording = Recording.start
          html = renderer.render(partial: descriptor.partial, locals: locals)
          trace = recording.prov
          node_digests = trace.node_digests_since({})
          node_texts = trace.nodes.keys.to_h { |a| [a, trace.text_for(a)] }
          [html, node_digests, node_texts, recording.read_set]
        ensure
          Recording.finish
          ActiveRecord::Base.connection_pool.release_connection
        end
      end
      html, node_digests, node_texts, read_set = thread.value
      Result.new(
        html: html, digest: Digest::SHA256.hexdigest(html),
        node_digests: node_digests, node_texts: node_texts, read_set: read_set
      )
    end
  end
end
