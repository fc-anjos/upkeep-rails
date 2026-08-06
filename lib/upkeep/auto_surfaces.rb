module Upkeep
  # Automatic surface detection: no declarations, no annotations. Every
  # TOP-LEVEL partial rendered during a captured GET whose locals are
  # rebuildable becomes a surface candidate, named by its template path.
  # The promotion machinery does all the deciding from there — most
  # candidates simply never assemble the evidence and stay Tier P, which
  # costs nothing (refresh is the sole correctness mechanism either way).
  #
  # Deliberately narrow at capture time:
  #   - depth guard: nested partials (including collection items) belong to
  #     their enclosing candidate, not to candidates of their own
  #   - explicit shared_surface blocks keep their own name and suppress
  #     auto-observation inside them
  #   - unrebuildable locals never register a candidate (nothing to scrub-
  #     render later), so noise never reaches the store
  module AutoSurfaces
    DEPTH_KEY = :upkeep_partial_depth
    SUPPRESS_KEY = :upkeep_auto_suppress

    class << self
      def suppress
        prev = Thread.current[SUPPRESS_KEY]
        Thread.current[SUPPRESS_KEY] = true
        yield
      ensure
        Thread.current[SUPPRESS_KEY] = prev
      end

      def suppressed? = !!Thread.current[SUPPRESS_KEY]

      def install!
        return if @installed
        @installed = true
        ActionView::PartialRenderer.prepend(PartialObserver)
      end
    end

    module PartialObserver
      def render_partial_template(view, locals, template, layout, block)
        recording = Recording.current
        depth = (Thread.current[DEPTH_KEY] || 0)
        candidate = recording && depth.zero? && !block && layout.nil? &&
                    !AutoSurfaces.suppressed? && template.virtual_path
        Thread.current[DEPTH_KEY] = depth + 1
        marker = candidate ? recording.prov&.segment_marker : nil
        result = super
        _upkeep_record_candidate(recording, locals, template, marker, result) if candidate
        result
      ensure
        Thread.current[DEPTH_KEY] = depth
      end

      private

      def _upkeep_record_candidate(recording, locals, template, marker, result)
        descriptor_locals = locals.except(:template) # internal riders stay out
        # virtual_path is "surfaces/_cards"; render(partial:) wants
        # "surfaces/cards".
        partial_name = template.virtual_path.sub(%r{(^|/)_([^/]+)\z}, '\1\2')
        descriptor = Descriptor.new(
          name: "auto:#{template.virtual_path}",
          partial: partial_name, locals: descriptor_locals
        )
        return unless descriptor.refreshable?
        node_digests = recording.prov ? recording.prov.node_digests_since(marker || {}) : {}
        recording.record_surface(
          name: descriptor.name, partial: descriptor.partial,
          locals: descriptor_locals, html: result.body.to_s,
          node_digests: node_digests,
          node_texts: node_digests.keys.to_h { |a| [a, recording.prov.text_for(a)] }
        )
        Upkeep.stats[:auto_surface_candidates] += 1
      end
    end
  end
end
