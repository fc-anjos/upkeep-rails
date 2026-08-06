require "digest"
require "herb"
require "reactionview"

module RefreshSync
  # Query→node provenance through Herb/ReActionView (ported from the spike).
  #
  # Compile time: templates under Provenance.instrument_paths compile through
  # the Herb engine with a visitor that brackets element/control-flow nodes
  # with Runtime.enter/leave calls carrying a structural address
  # (t:<source-digest>/<child-index path>). Expression nodes are NOT
  # bracketed (Herb trims differently there — see spike/FINDINGS.md); they
  # inherit the enclosing node's provenance. Element nodes in templates under
  # Provenance.stamp_paths additionally get a data-rs-node attribute so
  # region broadcasts can target them.
  #
  # Render time: a per-Recording Trace keeps the open-node stack and each
  # node's output-buffer segments. Cross-template containment comes from
  # EXPLICIT buffer links (parent buffer + offset recorded when a child
  # buffer first opens under a parent node, and at layout yield via
  # ActionView::OutputFlow#get) — never substring search.
  module Provenance
    Segment = Struct.new(:buffer_id, :start, :stop)

    class NodeRecord
      attr_reader :address, :file, :line, :segments

      def initialize(address, file, line)
        @address = address
        @file = file
        @line = line
        @segments = []
      end
    end

    # Per-Recording render trace.
    class Trace
      attr_reader :nodes

      def initialize
        @nodes = {}    # address => NodeRecord
        @buffers = {}  # buffer_id => buffer object
        @embeds = {}   # child buffer_id => [host buffer_id, offset]
        @stack = []    # [NodeRecord, buffer_id, start_offset]
        @injected = [] # [address, digest] — replayed from cached fragments
      end

      def enter(address, file, line, buffer)
        record = (@nodes[address] ||= NodeRecord.new(address, file, line))
        buffer_id = buffer.object_id
        unless @buffers.key?(buffer_id)
          @buffers[buffer_id] = buffer
          # A new buffer opening under an open node is a child template
          # (partial) whose output will land at the parent buffer's current
          # length — the explicit render-boundary link.
          if (top = @stack.last) && top[1] != buffer_id
            @embeds[buffer_id] = [top[1], buffer_bytesize(@buffers[top[1]])]
          end
        end
        @stack.push([record, buffer_id, buffer_bytesize(buffer)])
      end

      def leave(buffer)
        record, buffer_id, start = @stack.pop
        return unless record
        record.segments << Segment.new(buffer_id, start, buffer_bytesize(buffer))
      end

      def current_address
        @stack.last&.first&.address
      end

      # Layout yield: the page's finished buffer is appended into the layout
      # buffer at its current length. Called from OutputFlow#get.
      def link_flow(content)
        return unless (top = @stack.last)
        child_id = content.object_id
        return unless @buffers.key?(child_id) # only link buffers we traced
        host_buffer = @buffers[top[1]]
        @embeds[child_id] ||= [top[1], buffer_bytesize(host_buffer)]
      end

      def text_for(address)
        record = @nodes[address]
        return nil unless record
        record.segments.map { |seg| slice(seg) }.join
      end

      # {address => sha256 of the text produced since `marker`} for nodes
      # that emitted output in that window (used per-surface-render).
      # Injected digests (fragment-cache replays — a warm fragment's nodes
      # never execute, so their unchanged digests are replayed alongside its
      # read set) merge in with the same window semantics.
      def segment_marker
        @nodes.transform_values { |r| r.segments.size }.merge("__injected" => @injected.size)
      end

      def node_digests_since(marker)
        live = @nodes.filter_map do |address, record|
          fresh = record.segments.drop(marker[address].to_i)
          next if fresh.empty?
          [address, Digest::SHA256.hexdigest(fresh.map { |seg| slice(seg) }.join)]
        end.to_h
        @injected.drop(marker["__injected"].to_i).to_h.merge(live)
      end

      # A cached fragment's node digests: bytes identical to the capture-time
      # render (that is what fragment caching means), so the digests remain
      # valid evidence while the fragment is warm.
      def inject_digest(address, digest)
        @injected << [address, digest]
      end

      # Root-coordinate byte ranges per address, using explicit embeds only.
      # Unlinked buffers stay in their own coordinate space (their offsets
      # are namespaced by root id so cross-tree containment never
      # false-positives).
      def absolute_ranges
        @nodes.transform_values do |record|
          record.segments.map do |seg|
            root, offset = resolve(seg.buffer_id)
            [root, offset + seg.start, offset + seg.stop]
          end
        end
      end

      private

      def resolve(buffer_id)
        offset = 0
        seen = Set.new
        while (link = @embeds[buffer_id])
          break if seen.include?(buffer_id)
          seen << buffer_id
          buffer_id = link[0]
          offset += link[1]
        end
        [buffer_id, offset]
      end

      def slice(seg)
        raw(@buffers[seg.buffer_id]).byteslice(seg.start, seg.stop - seg.start).to_s
      end

      def raw(buffer)
        return "" unless buffer
        (buffer.respond_to?(:raw_buffer) ? buffer.raw_buffer : buffer.to_s).to_s
      end

      def buffer_bytesize(buffer)
        raw(buffer).bytesize
      end
    end

    # Called from compiled template code. No-ops (one thread-local read)
    # unless a Recording is active on this thread.
    module Runtime
      def self.enter(address, file, line, buffer)
        Recording.current&.prov&.enter(address, file, line, buffer)
      end

      def self.leave(buffer)
        Recording.current&.prov&.leave(buffer)
      end

      def self.current_address
        Recording.current&.prov&.current_address
      end
    end

    # Layout yield link (see Trace#link_flow).
    module FlowObserver
      def get(key)
        content = super
        Recording.current&.prov&.link_flow(content) if content
        content
      end
    end

    # Compile-time AST visitor: brackets instrumentable nodes, stamps
    # data-rs-node on element open tags when stamping is on. One shared
    # instance is registered; per-document state is reset in
    # visit_document_node (transform_visitors instances are shared across
    # compiles — the one shared-mutable-state hazard, single-threaded under
    # ActionView's template lock).
    class Visitor < ::Herb::Visitor
      INSTRUMENTABLE = %w[
        HTMLElementNode ERBBlockNode ERBIfNode ERBUnlessNode ERBCaseNode
        ERBForNode ERBWhileNode
      ].freeze

      def visit_document_node(node)
        context = Thread.current[Handler::CONTEXT_KEY]
        return if context.nil?

        source = node.respond_to?(:source) ? node.source : nil
        @digest = source ? Digest::SHA256.hexdigest(source)[0, 12] : context[:digest]
        return if @digest.nil?

        @file = context[:file]
        @stamp = context[:stamp]
        instrument_children(node, [])
        nil
      end

      private

      ARRAY_PROPS = [:children, :body, :statements].freeze
      NODE_PROPS = [:subsequent, :else_clause, :end_node, :rescue_clause, :ensure_clause].freeze

      def instrument_children(node, path)
        ARRAY_PROPS.each do |prop|
          next unless node.respond_to?(prop) && node.send(prop).is_a?(Array)
          array = node.send(prop)
          rewritten = []
          array.each_with_index do |child, index|
            child_path = path + ["#{prop}#{index}"]
            if instrument?(child)
              address = address_for(child_path)
              stamp_element(child, address) if @stamp
              instrument_children(child, child_path)
              line = child.location&.start&.line || 0
              rewritten << code_node("::RefreshSync::Provenance::Runtime.enter(#{address.inspect}, #{@file.inspect}, #{line}, @output_buffer)")
              rewritten << child
              rewritten << code_node("::RefreshSync::Provenance::Runtime.leave(@output_buffer)")
            else
              instrument_children(child, child_path) if child.respond_to?(:accept)
              rewritten << child
            end
          end
          array.replace(rewritten)
        end

        NODE_PROPS.each do |prop|
          next unless node.respond_to?(prop) && node.send(prop)
          instrument_children(node.send(prop), path + [prop.to_s])
        end
      end

      def instrument?(child)
        INSTRUMENTABLE.include?(child.class.name&.split("::")&.last)
      end

      def address_for(path)
        "t:#{@digest}/#{path.join(".")}"
      end

      def stamp_element(child, address)
        return unless child.class.name&.end_with?("HTMLElementNode")
        open_tag = child.open_tag
        return unless open_tag && open_tag.respond_to?(:children)
        open_tag.children << attribute_node("data-rs-node", address)
      end

      def dummy_location = @dummy_location ||= ::Herb::Location.from(0, 0, 0, 0)
      def dummy_range = @dummy_range ||= ::Herb::Range.from(0, 0)

      def token(type, value)
        ::Herb::Token.new(value.dup, dummy_range, dummy_location, type.to_s)
      end

      def code_node(code)
        ::Herb::AST::ERBContentNode.new(
          "ERBContentNode", dummy_location, [],
          token(:tag_opening, "<%"),
          token(:content, " #{code} "),
          token(:tag_closing, "%>"),
          nil, true, true, nil
        )
      end

      def attribute_node(name, value)
        name_literal = ::Herb::AST::LiteralNode.new("LiteralNode", dummy_location, [], name.dup)
        name_node = ::Herb::AST::HTMLAttributeNameNode.new("HTMLAttributeNameNode", dummy_location, [], [name_literal])
        value_literal = ::Herb::AST::LiteralNode.new("LiteralNode", dummy_location, [], value.dup)
        value_node = ::Herb::AST::HTMLAttributeValueNode.new(
          "HTMLAttributeValueNode", dummy_location, [], token(:quote, '"'), [value_literal], token(:quote, '"'), true
        )
        ::Herb::AST::HTMLAttributeNode.new(
          "HTMLAttributeNode", dummy_location, [], name_node, token(:equals, "="), value_node
        )
      end
    end

    # ERB handler: templates under instrument_paths compile through Herb with
    # the provenance visitor; everything else (inline templates, other
    # formats, foreign paths) keeps stock ERB byte-for-byte.
    class Handler < ::ActionView::Template::Handlers::ERB
      CONTEXT_KEY = :refresh_sync_prov_template

      def call(template, source)
        identifier = template.respond_to?(:identifier) ? template.identifier.to_s : ""
        if template.format == :html && Provenance.instrument_path?(identifier)
          Thread.current[CONTEXT_KEY] = {
            file: identifier.sub(%r{\A.*/test/views/}, ""),
            digest: Digest::SHA256.hexdigest(source.to_s)[0, 12],
            stamp: Provenance.stamp_path?(identifier)
          }
          ::ReActionView::Template::Handlers::Herb.call(template, source)
        else
          super
        end
      ensure
        Thread.current[CONTEXT_KEY] = nil
      end
    end

    class << self
      attr_writer :instrument_paths, :stamp_paths

      def instrument_paths = @instrument_paths ||= []
      def stamp_paths = @stamp_paths ||= []

      def instrument_path?(identifier)
        instrument_paths.any? { |p| identifier.start_with?(p) }
      end

      def stamp_path?(identifier)
        stamp_paths.any? { |p| identifier.start_with?(p) }
      end

      def install!
        return if @installed
        @installed = true
        require "reactionview"
        ReActionView.config.transform_visitors << Visitor.new
        ActionView::Template.register_template_handler(:erb, Handler)
        ActionView::OutputFlow.prepend(FlowObserver)
      end

      # Compare two traces' node output. Returns divergent addresses, the
      # innermost divergent ones (containment from absolute byte ranges —
      # explicit links only), and the byte-shared remainder.
      def localize(trace_a, trace_b)
        addresses = trace_a.nodes.keys | trace_b.nodes.keys
        differing = addresses.select do |address|
          trace_a.text_for(address) != trace_b.text_for(address)
        end

        ranges_a = trace_a.absolute_ranges
        ranges_b = trace_b.absolute_ranges
        covers = lambda do |outer, inner, ranges|
          ro = ranges[outer]
          ri = ranges[inner]
          next false unless ro && ri && ri.any? { |_root, s, e| e > s }
          ri.all? do |root, s, e|
            ro.any? { |oroot, os, oe| root == oroot && os <= s && e <= oe }
          end
        end
        depth = ->(address) { address.count(".") }
        # Byte-equal ranges (a control-flow node and its only child) tie-break
        # by path depth: the deeper node is the inner one.
        encloses = lambda do |outer, inner|
          next false unless covers.call(outer, inner, ranges_a) || covers.call(outer, inner, ranges_b)
          if (covers.call(inner, outer, ranges_a) || covers.call(inner, outer, ranges_b))
            depth.call(outer) < depth.call(inner)
          else
            true
          end
        end

        innermost = differing.reject do |address|
          differing.any? { |other| other != address && encloses.call(address, other) }
        end

        { differing: differing.sort, innermost: innermost.sort, shared: (addresses - differing).sort }
      end
    end
  end
end
