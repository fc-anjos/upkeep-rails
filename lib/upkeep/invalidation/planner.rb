# frozen_string_literal: true

require "active_support/notifications"

module Upkeep
  module Invalidation
    class Planner
      PlannedTarget = Data.define(
        :subscription_id,
        :subscriber_id,
        :target,
        :frame_id,
        :identity_signature,
        :sharing_signature,
        :recipe,
        :matched_dependency_keys,
        :action,
        :deoptimization_reason
      ) do
        def render
          recipe.render
        end
      end

      Plan = Data.define(:targets, :candidate_entries, :matched_entries) do
        def summary
          {
            targets: targets.size,
            candidate_entries: candidate_entries.size,
            matched_entries: matched_entries.size,
            target_kinds: targets.map { |target| target.target.kind }.uniq.sort,
            deoptimizations: targets.filter_map(&:deoptimization_reason).tally
          }
        end
      end

      def initialize(store:)
        @store = store
      end

      def plan(changes)
        changes = Array(changes)
        payload = { change_count: changes.size }
        ActiveSupport::Notifications.instrument("plan.upkeep", payload) do
          candidate_entries = store.reverse_index.entries_for(changes)
          matched_entries = candidate_entries.select { |entry| changes.any? { |change| entry.dependency.matches_change?(change) } }

          targets = matched_entries
            .group_by(&:subscription_id)
            .flat_map { |subscription_id, entries| targets_for_subscription(store.fetch(subscription_id), entries, changes) }

          plan = Plan.new(deduplicate_targets(targets), candidate_entries, matched_entries)
          payload.merge!(payload_for(plan))
          plan
        end
      end

      private

      attr_reader :store

      def payload_for(plan)
        {
          candidate_entries: plan.candidate_entries.size,
          matched_entries: plan.matched_entries.size,
          targets: plan.targets.size,
          target_kinds: plan.targets.map { |target| target.target.kind }.uniq.sort,
          actions: plan.targets.map(&:action).tally,
          deoptimizations: plan.targets.filter_map(&:deoptimization_reason).tally
        }
      end

      def targets_for_subscription(subscription, entries, changes)
        frames_by_id = Hash.new { |hash, key| hash[key] = { node: nil, dependency_keys: [], entries: [] } }

        entries.each do |entry|
          subscription.graph.nearest_frame_nodes_from(entry.owner_id).each do |frame|
            bucket = frames_by_id[frame.id]
            bucket[:node] ||= frame
            bucket[:dependency_keys] << entry.dependency_cache_key
            bucket[:entries] << entry
          end
        end

        remove_contained_frames(subscription.graph, frames_by_id.values.map { |bucket| bucket.fetch(:node) }, changes: changes).filter_map do |frame|
          bucket = frames_by_id.fetch(frame.id)
          build_target(subscription, frame, bucket.fetch(:dependency_keys).uniq, bucket.fetch(:entries), changes)
        end
      end

      def remove_contained_frames(graph, frames, changes:)
        frames = prefer_render_sites_for_destroy(graph, frames.uniq(&:id), changes)

        frames.reject do |frame|
          frames.any? { |candidate| candidate.id != frame.id && graph.contained_by?(frame.id, candidate.id) }
        end
      end

      def prefer_render_sites_for_destroy(graph, frames, changes)
        return frames unless changes.any? { |change| destroy_change?(change) }

        render_sites = frames.select { |frame| frame.payload.fetch(:kind) == "render_site" }
        return frames if render_sites.empty?

        frames.reject do |frame|
          frame.payload.fetch(:kind) == "page" &&
            render_sites.any? { |render_site| graph.contained_by?(render_site.id, frame.id) }
        end
      end

      def build_target(subscription, frame, dependency_keys, entries, changes)
        target = target_for_frame(frame)
        return unless target

        frame_id = Targeting::Extraction.frame_id_for(target)
        recipe = subscription.replay_recipe(frame_id)
        return unless recipe

        identity_signature = subscription.identity_signature(frame_id)
        sharing_signature = SharedStreams.signature_for(recipe) if identity_signature == "public" && frame.payload.fetch(:kind) == "render_site"
        action, recipe, delivery_target, deoptimization_reason = delivery_strategy(frame, recipe, entries, changes)
        target = delivery_target || target

        PlannedTarget.new(
          subscription.id,
          subscription.subscriber_id,
          target,
          frame_id,
          identity_signature,
          sharing_signature,
          recipe,
          dependency_keys,
          action,
          deoptimization_reason
        )
      end

      def target_for_frame(frame)
        case frame.payload.fetch(:kind)
        when "page"
          Targeting::Target.new("page", frame.id, "page frame dependency matched committed change")
        when "render_site"
          Targeting::Target.new("render_site", frame.payload.fetch(:site_id), "render-site dependency matched committed change")
        when "fragment"
          Targeting::Target.new("fragment", frame.id, "record attribute read matched committed attributes")
        end
      end

      def delivery_strategy(frame, recipe, entries, changes)
        remove_recipe = remove_recipe_for(frame, recipe, entries, changes)
        if remove_recipe
          return [
            "remove",
            remove_recipe,
            target_for_recipe(remove_recipe, "render-site member was destroyed"),
            nil
          ]
        end

        append_recipe = append_recipe_for(frame, recipe, entries, changes)
        return ["append", append_recipe, nil, nil] if append_recipe

        prepend_recipe = prepend_recipe_for(frame, recipe, entries, changes)
        return ["prepend", prepend_recipe, nil, nil] if prepend_recipe

        member_replace_recipe = member_replace_recipe_for(frame, recipe, entries, changes)
        if member_replace_recipe
          delivery_target = target_for_recipe(member_replace_recipe, "render-site member update kept collection order")
          return ["replace", member_replace_recipe, delivery_target, nil]
        end

        ["replace", recipe, nil, deoptimization_reason(frame, entries, changes)]
      end

      def append_recipe_for(frame, recipe, entries, changes)
        return unless frame.payload.fetch(:kind) == "render_site"
        return unless entries.any? { |entry| entry.dependency.source == :active_record_collection }

        create_changes = changes.select { |change| change[:id] && change.fetch(:type).to_s.include?("create") }
        return unless create_changes.one?

        CollectionAppend.build(recipe: recipe, change: create_changes.first)
      end

      def prepend_recipe_for(frame, recipe, entries, changes)
        return unless frame.payload.fetch(:kind) == "render_site"
        return unless entries.any? { |entry| entry.dependency.source == :active_record_collection }

        create_changes = changes.select { |change| change[:id] && change.fetch(:type).to_s.include?("create") }
        return unless create_changes.one?

        CollectionPrepend.build(recipe: recipe, change: create_changes.first)
      end

      def member_replace_recipe_for(frame, recipe, entries, changes)
        return unless frame.payload.fetch(:kind) == "render_site"
        return unless entries.any? { |entry| entry.dependency.source == :active_record_collection }

        update_changes = changes.select do |change|
          change[:id] && !change.fetch(:type).to_s.include?("create") && !destroy_change?(change)
        end
        return unless update_changes.one?

        CollectionMemberReplace.build(recipe: recipe, change: update_changes.first)
      end

      def remove_recipe_for(frame, recipe, entries, changes)
        return unless frame.payload.fetch(:kind) == "render_site"
        return unless entries.any? { |entry| entry.dependency.source == :active_record_collection }

        destroy_changes = changes.select do |change|
          change[:id] && destroy_change?(change)
        end
        return unless destroy_changes.one?

        CollectionRemove.build(recipe: recipe, change: destroy_changes.first)
      end

      def deoptimization_reason(frame, entries, changes)
        return unless frame.payload.fetch(:kind) == "render_site"
        return unless entries.any? { |entry| entry.dependency.source == :active_record_collection }

        if changes.one? { |change| change[:id] && change.fetch(:type).to_s.include?("create") }
          "collection_create_position_unproven"
        elsif changes.one? { |change| change[:id] && destroy_change?(change) }
          "collection_remove_unproven"
        elsif changes.one? { |change| change[:id] && !change.fetch(:type).to_s.include?("create") && !destroy_change?(change) }
          "collection_member_replace_unproven"
        else
          "collection_multi_change_fallback"
        end
      end

      def destroy_change?(change)
        type = change.fetch(:type).to_s
        type.include?("destroy") || type.include?("delete")
      end

      def target_for_recipe(recipe, reason)
        Targeting::Target.new(recipe.target_kind, recipe.target_id, reason)
      end

      def deduplicate_targets(targets)
        targets.each_with_object({}) do |target, indexed_targets|
          key = [
            target.subscriber_id,
            target.target.kind,
            target.target.id,
            target.identity_signature,
            target.sharing_signature,
            target.action,
            target.deoptimization_reason
          ]
          indexed_targets[key] = merge_target(indexed_targets[key], target)
        end.values
      end

      def merge_target(existing, target)
        return target unless existing

        PlannedTarget.new(
          existing.subscription_id,
          existing.subscriber_id,
          existing.target,
          existing.frame_id,
          existing.identity_signature,
          existing.sharing_signature,
          existing.recipe,
          (existing.matched_dependency_keys + target.matched_dependency_keys).uniq,
          existing.action,
          existing.deoptimization_reason
        )
      end
    end
  end
end
