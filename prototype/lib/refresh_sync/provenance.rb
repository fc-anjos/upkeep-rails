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

    # Per-render-instance identity: a node inside a loop body is entered once
    # per iteration; all iterations would otherwise share one address (and a
    # one-row change would replace the whole list). When the node's PARENT
    # has materialized records of exactly one table (the loop node owns the
    # collection load — ids arrive in result order before the first
    # iteration renders), the n-th entry of a child address is bound to the
    # n-th loaded id and traced under "address@table:id". Identity is
    # runtime evidence, never authored, and FAILS CLOSED: any sign the
    # ordinal<->row correspondence is unsound (attribute reads of a
    # different row inside the instance window, entry counts that disagree
    # with the loaded id count, an instance address entered twice) marks the
    # base address unsound and its digests collapse to an "__unsound__"
    # marker, which region delivery treats as a structural change
    # (whole-region replace, never a row-targeted one).
    UNSOUND = "__unsound__".freeze

    def self.base_of(address)
      address.split("@", 2).first
    end

    def self.instance?(address)
      address.include?("@")
    end

    # Per-Recording render trace.
    class Trace
      Frame = Struct.new(:record, :buffer_id, :start, :identity, :identity_base,
                         :child_counts, :iterated)

      attr_reader :nodes, :unsound_bases

      def initialize(iteration_ids: nil)
        @nodes = {}    # instance address => NodeRecord
        @buffers = {}  # buffer_id => buffer object
        @embeds = {}   # child buffer_id => [host buffer_id, offset]
        @stack = []    # [Frame]
        @injected = [] # [address, digest] — replayed from cached fragments
        # ->(parent_address) { [table, ordered_ids] | nil } — the read-set
        # bridge that supplies per-iteration record identity.
        @iteration_ids = iteration_ids
        @unsound_bases = Set.new
      end

      def enter(address, file, line, buffer)
        identity, identity_base, own = instance_identity(address)
        instance_address = identity ? "#{address}@#{identity}" : address
        if own && @nodes.key?(instance_address)
          # The same (address, record) pair rendered twice — nested loops
          # collapsing onto one identity, duplicate rows: not row-targetable.
          @unsound_bases << address
        end
        record = (@nodes[instance_address] ||= NodeRecord.new(instance_address, file, line))
        buffer_id = buffer.object_id
        unless @buffers.key?(buffer_id)
          @buffers[buffer_id] = buffer
          # A new buffer opening under an open node is a child template
          # (partial) whose output will land at the parent buffer's current
          # length — the explicit render-boundary link.
          if (top = @stack.last) && top.buffer_id != buffer_id
            @embeds[buffer_id] = [top.buffer_id, buffer_bytesize(@buffers[top.buffer_id])]
          end
        end
        @stack.push(Frame.new(record, buffer_id, buffer_bytesize(buffer),
                              identity, identity_base, nil, nil))
      end

      def leave(buffer)
        frame = @stack.pop
        return unless frame&.record
        frame.record.segments << Segment.new(frame.buffer_id, frame.start, buffer_bytesize(buffer))
        verify_iterations(frame)
      end

      def current_address
        @stack.last&.record&.address
      end

      # Attribute-read verification: reading a row of the identity table
      # that is NOT the row bound to the innermost identity frame means the
      # ordinal<->row correspondence broke (conditional skips, reordering).
      def note_attribute_read(table, id)
        return if id.nil?
        frame = @stack.reverse_each.find(&:identity)
        return unless frame
        itable, iid = frame.identity.split(":", 2)
        return unless itable == table
        @unsound_bases << frame.identity_base if iid != id.to_s
      end

      # Layout yield: the page's finished buffer is appended into the layout
      # buffer at its current length. Called from OutputFlow#get.
      def link_flow(content)
        return unless (top = @stack.last)
        child_id = content.object_id
        return unless @buffers.key?(child_id) # only link buffers we traced
        host_buffer = @buffers[top.buffer_id]
        @embeds[child_id] ||= [top.buffer_id, buffer_bytesize(host_buffer)]
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
        live = {}
        @nodes.each do |address, record|
          fresh = record.segments.drop(marker[address].to_i)
          next if fresh.empty?
          base = Provenance.base_of(address)
          if @unsound_bases.include?(base)
            # Unsound iteration mapping: collapse every instance of the base
            # to one marker entry. Identical for every viewer (soundness is
            # a structural property of the render, not of the viewer), so it
            # never manufactures divergence — but it always differs from a
            # real digest, so region delivery falls back to a whole-region
            # replace instead of trusting per-row identity.
            live[base] = UNSOUND
          else
            live[address] = Digest::SHA256.hexdigest(fresh.map { |seg| slice(seg) }.join)
          end
        end
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

      # [identity, identity_base, own?] for a node being entered.
      # Own identity: the parent frame's node materialized records of exactly
      # one table before this child rendered, and this is the ordinal-th
      # entry of this child address under the current parent entry — bind to
      # the ordinal-th loaded id. Otherwise identity is inherited from the
      # nearest identified ancestor (nodes inside a row belong to that row).
      def instance_identity(address)
        parent = @stack.last
        return [nil, nil, false] unless parent
        if @iteration_ids && (loaded = @iteration_ids.call(parent.record.address))
          table, ids = loaded
          parent.child_counts ||= Hash.new(0)
          ordinal = parent.child_counts[address]
          parent.child_counts[address] += 1
          if ordinal < ids.size
            (parent.iterated ||= Hash.new(0))[address] += 1
            return ["#{table}:#{ids[ordinal]}", address, true]
          else
            # More entries than loaded rows: the correspondence is broken
            # for every instance of this address.
            @unsound_bases << address
            return [parent.identity, parent.identity_base, false]
          end
        end
        [parent.identity, parent.identity_base, false]
      end

      # On leaving a parent that assigned iteration identities: the number
      # of entries per child address must equal the number of loaded ids —
      # anything else (conditional `next`, early `break`, mixed plain
      # entries) voids row identity for that address.
      def verify_iterations(frame)
        return unless frame.iterated
        _table, ids = @iteration_ids.call(frame.record.address)
        frame.iterated.each do |address, own_count|
          if ids.nil? || own_count != ids.size || frame.child_counts[address] != own_count
            @unsound_bases << address
          end
        end
      end

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

      # data-rs-node attribute value, resolved at render time: the current
      # trace frame's INSTANCE address (per-iteration identity included) when
      # capturing, the compile-time base address otherwise. The enter call is
      # injected immediately before the element, so during the open tag's
      # render the top of the stack is this element's own frame.
      def self.stamp(fallback)
        Recording.current&.prov&.current_address || fallback
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

      # The stamp value is a render-time expression, not a literal: inside a
      # loop each iteration must carry its own instance address so a single
      # row can be targeted. Outside capture (and for non-iterated nodes)
      # Runtime.stamp returns the base address — byte-identical to the old
      # literal stamp.
      def stamp_element(child, address)
        return unless child.class.name&.end_with?("HTMLElementNode")
        open_tag = child.open_tag
        return unless open_tag && open_tag.respond_to?(:children)
        code = "::RefreshSync::Provenance::Runtime.stamp(#{address.inspect})"
        open_tag.children << attribute_node("data-rs-node", output_node(code))
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

      # An ERB output node (<%= code %>): herb compiles it inside an
      # attribute value via ::Herb::Engine.attr (probed; whole-attribute ERB
      # position is rejected by the engine's security check, value position
      # is supported).
      def output_node(code)
        ::Herb::AST::ERBContentNode.new(
          "ERBContentNode", dummy_location, [],
          token(:tag_opening, "<%="),
          token(:content, " #{code} "),
          token(:tag_closing, "%>"),
          nil, true, true, nil
        )
      end

      def attribute_node(name, value)
        name_literal = ::Herb::AST::LiteralNode.new("LiteralNode", dummy_location, [], name.dup)
        name_node = ::Herb::AST::HTMLAttributeNameNode.new("HTMLAttributeNameNode", dummy_location, [], [name_literal])
        value_child =
          value.is_a?(::Herb::AST::Node) ? value : ::Herb::AST::LiteralNode.new("LiteralNode", dummy_location, [], value.dup)
        value_node = ::Herb::AST::HTMLAttributeValueNode.new(
          "HTMLAttributeValueNode", dummy_location, [], token(:quote, '"'), [value_child], token(:quote, '"'), true
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
