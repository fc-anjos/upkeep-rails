# frozen_string_literal: true

require "digest"

module Upkeep
  module SharedStreams
    PREFIX = "upkeep:shared"

    module_function

    def stream_name(target:, identity_signature:, sharing_signature:)
      digest = Digest::SHA256.hexdigest([target.kind, target.id, identity_signature, sharing_signature].inspect)[0, 32]
      "#{PREFIX}:#{digest}"
    end

    def signature_for(recipe)
      Digest::SHA256.hexdigest(recipe.to_h.inspect)
    end

    def names_for_subscription(subscription)
      names_for_graph(subscription.graph)
    end

    def names_for_recorder(recorder)
      names_for_graph(recorder.graph)
    end

    def names_for_graph(graph)
      graph.frame_nodes.filter_map do |frame|
        next unless frame.payload.fetch(:kind) == "render_site"

        recipe = frame.payload[:recipe]
        next unless recipe

        identity_signature = identity_signature_for(graph, frame.id)
        next unless identity_signature == "public"

        target = target_for_frame(frame)
        next unless target

        stream_name(
          target: target,
          identity_signature: identity_signature,
          sharing_signature: signature_for(recipe)
        )
      end.uniq.sort
    end

    def identity_signature_for(graph, frame_id)
      identity_dependencies = graph.contained_node_ids(frame_id)
        .flat_map { |owner_id| graph.dependencies_for(owner_id) }
        .select(&:identity?)
        .uniq(&:cache_key)
      return "public" if identity_dependencies.empty?

      Digest::SHA256.hexdigest(identity_dependencies.map(&:identity_key).sort_by(&:inspect).inspect)[0, 16]
    end

    def target_for_frame(frame)
      case frame.payload.fetch(:kind)
      when "render_site"
        Targeting::Target.new("render_site", frame.payload.fetch(:site_id), "shared render-site frame")
      end
    end
  end
end
