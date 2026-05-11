# frozen_string_literal: true

require "json"
require_relative "prom_parse"

module Upkeep
  module Benchmark
    module RelayMetricsSnapshot
      module_function

      def merge_into(app_metrics, prometheus_body)
        data = app_metrics || {}
        relay = snapshot(prometheus_body)

        data["counters"] ||= {}
        data["counters"]["transmits_total"] = (data.dig("counters", "transmits") || 0) + relay.dig("counters", "client_frames_sent_total").to_i
        data["relay"] = relay
        data
      end

      def snapshot(prometheus_body)
        parsed = PromParse.parse(prometheus_body)
        groups = sum_counter(parsed, "upkeep_relay_render_groups_total")
        savings = sum_counter(parsed, "upkeep_relay_render_dedup_savings_total")
        subs_served = groups + savings

        {
          "counters" => {
            "client_frames_sent_total" => sum_counter(parsed, "upkeep_relay_client_frames_sent_total"),
            "client_frames_dropped_no_connection_total" => sum_counter(parsed, "upkeep_relay_client_frames_dropped_no_connection_total"),
            "client_frames_closed_total" => sum_counter(parsed, "upkeep_relay_client_frames_closed_total"),
            "client_frames_dropped_overflow_total" => sum_counter(parsed, "upkeep_relay_client_frames_dropped_overflow_total"),
            "delivery_payload_serializations_total" => sum_counter(parsed, "upkeep_relay_delivery_payload_serializations_total"),
            "delivery_payload_bytes_total" => sum_counter(parsed, "upkeep_relay_delivery_payload_bytes_total"),
            "delivery_fanout_recipients_total" => sum_counter(parsed, "upkeep_relay_delivery_fanout_recipients_total"),
            "client_acks_total" => sum_counter(parsed, "upkeep_relay_client_acks_total"),
            "delivery_skipped_unchanged_total" => sum_counter(parsed, "upkeep_relay_delivery_skipped_unchanged_total"),
            "delivery_skipped_sid_gone_total" => sum_counter(parsed, "upkeep_relay_delivery_skipped_sid_gone_total"),
            "delivery_sids_without_payload_total" => sum_counter(parsed, "upkeep_relay_delivery_sids_without_payload_total"),
            "invalidation_echo_suppressed_total" => sum_counter(parsed, "upkeep_relay_invalidation_echo_suppressed_total"),
            "render_call_errors_total" => sum_counter(parsed, "upkeep_relay_render_call_errors_total"),
            "render_batches_empty_fragments_total" => sum_counter(parsed, "upkeep_relay_render_batches_empty_fragments_total"),
            "render_groups_empty_members_total" => sum_counter(parsed, "upkeep_relay_render_groups_empty_members_total"),
            "render_groups_total" => groups,
            "render_dedup_savings_total" => savings,
            "replay_forced_groups_total" => sum_counter(parsed, "upkeep_relay_replay_forced_groups_total"),
            "classification_downgrades_total" => sum_counter(parsed, "upkeep_relay_classification_downgrades_total"),
            "dedup_ratio" => subs_served.zero? ? 0.0 : (savings.to_f / subs_served).round(4)
          },
          "render_groups_by_bucket" => by_label(parsed, "upkeep_relay_render_groups_total", "size_bucket"),
          "render_groups_by_tier" => by_label(parsed, "upkeep_relay_render_groups_by_tier", "tier"),
          "render_groups_by_mode" => by_label(parsed, "upkeep_relay_render_groups_by_mode", "mode"),
          "render_call_errors_by_kind" => by_label(parsed, "upkeep_relay_render_call_errors_total", "kind"),
          "render_calls_by_mode" => by_label(parsed, "upkeep_relay_render_calls_total", "mode"),
          "render_mode" => {
            "by_mode" => by_label(parsed, "upkeep_relay_render_fragments_by_mode_total", "mode"),
            "by_reason" => by_label_pair(parsed, "upkeep_relay_render_fragments_by_reason_total", "mode", "reason")
          },
          "proof_fallback" => {
            "by_reason" => by_label(parsed, "upkeep_relay_proof_fallbacks_total", "reason")
          },
          "proof_proven" => {
            "by_reason" => by_label(parsed, "upkeep_relay_proof_proven_total", "reason")
          },
          "runtime_contradiction" => {
            "by_mode" => by_label(parsed, "upkeep_relay_runtime_contradictions_total", "mode"),
            "by_reason" => by_label_pair(parsed, "upkeep_relay_runtime_contradictions_total", "mode", "reason")
          },
          "render_scheduling" => {
            "queue_delay" => histogram_summary(parsed, "upkeep_relay_render_group_queue_delay_seconds"),
            "checkout_wait" => histogram_summary(parsed, "upkeep_relay_render_checkout_wait_seconds"),
            "fallback_duration_by_mode" => histogram_summary_by_label(parsed, "upkeep_relay_per_sid_fallback_duration_seconds", "mode"),
            "dispatcher_in_flight_last" => gauge_value(parsed, "upkeep_relay_render_dispatcher_in_flight"),
            "checkout_available_slots_last" => gauge_value(parsed, "upkeep_relay_render_checkout_available_slots")
          },
          "region_gating" => {
            "no_digests_total" => sum_counter(parsed, "upkeep_relay_region_gating_no_digests_total"),
            "missing_manifest_total" => sum_counter(parsed, "upkeep_relay_region_gating_missing_manifest_total"),
            "user_keyed_total" => sum_counter(parsed, "upkeep_relay_region_gating_user_keyed_total"),
            "page_replay_mode_total" => sum_counter(parsed, "upkeep_relay_region_gating_page_replay_mode_total"),
            "eligible_total" => sum_counter(parsed, "upkeep_relay_region_gating_eligible_total")
          },
          "region_cache" => {
            "hit_total" => sum_counter(parsed, "upkeep_relay_region_cache_hit_total"),
            "miss_total" => sum_counter(parsed, "upkeep_relay_region_cache_miss_total"),
            "hit_by_region" => by_label(parsed, "upkeep_relay_region_cache_hit_total", "region_id"),
            "miss_by_region" => by_label(parsed, "upkeep_relay_region_cache_miss_total", "region_id")
          },
          "fanout" => {
            "duration" => histogram_summary(parsed, "upkeep_relay_delivery_fanout_duration_seconds"),
            "per_connection_enqueue" => histogram_summary(parsed, "upkeep_relay_delivery_per_connection_enqueue_seconds"),
            "supersession_actions" => by_label(parsed, "upkeep_relay_delivery_supersession_actions_total", "action")
          }
        }
      end

      # Summarise a histogram whose samples live under `<name>_bucket`,
      # `<name>_sum`, and `<name>_count`. Returns `{count:, sum:, p95:}` where
      # `p95` is the smallest bucket upper-bound containing the 95th-percentile
      # sample (approximate — fine for benchmark comparisons). Returns nil
      # when the histogram has no samples.
      def histogram_summary(parsed, metric_name)
        count = sum_counter(parsed, "#{metric_name}_count")
        return nil if count.zero?
        sum = sum_counter_float(parsed, "#{metric_name}_sum")
        {
          "count" => count,
          "sum_seconds" => sum.round(6),
          "p95_upper_bound_seconds" => histogram_p95_upper_bound(parsed, metric_name, count)
        }
      end

      def histogram_summary_by_label(parsed, metric_name, label_name)
        entries = parsed["#{metric_name}_count"] || {}
        entries.each_with_object({}) do |(labels, _), out|
          label_value = labels[label_name]
          next if label_value.nil?
          next if out.key?(label_value)

          label_count = entries.select { |l, _| l[label_name] == label_value }.values.sum.to_i
          next if label_count.zero?

          sum_entries = parsed["#{metric_name}_sum"] || {}
          label_sum = sum_entries.select { |l, _| l[label_name] == label_value }.values.sum.to_f
          p95 = histogram_p95_upper_bound_labelled(parsed, metric_name, label_name, label_value, label_count)
          out[label_value] = {
            "count" => label_count,
            "sum_seconds" => label_sum.round(6),
            "p95_upper_bound_seconds" => p95
          }
        end
      end

      def histogram_p95_upper_bound(parsed, metric_name, count)
        buckets = parsed["#{metric_name}_bucket"] || {}
        threshold = (count * 0.95).ceil
        ordered = buckets.map { |labels, value| [ parse_bucket_upper_bound(labels["le"]), value.to_i ] }
                          .reject { |ub, _| ub.nil? }
                          .sort_by(&:first)
        ordered.each do |ub, cumulative|
          return ub if cumulative >= threshold
        end
        nil
      end

      def histogram_p95_upper_bound_labelled(parsed, metric_name, label_name, label_value, label_count)
        buckets = parsed["#{metric_name}_bucket"] || {}
        threshold = (label_count * 0.95).ceil
        ordered = buckets
          .select { |labels, _| labels[label_name] == label_value }
          .map { |labels, value| [ parse_bucket_upper_bound(labels["le"]), value.to_i ] }
          .reject { |ub, _| ub.nil? }
          .sort_by(&:first)
        ordered.each do |ub, cumulative|
          return ub if cumulative >= threshold
        end
        nil
      end

      # The "+Inf" bucket has no finite upper bound. We surface +Inf
      # samples as a sentinel upper-bound (large but JSON-encodable) so
      # comparison reports stay greppable; callers that need the exact
      # bucket should inspect the raw Prometheus body. `nil` for bare
      # non-numeric labels.
      INFINITE_BUCKET_SENTINEL = 1.0e12

      def parse_bucket_upper_bound(value)
        return INFINITE_BUCKET_SENTINEL if value == "+Inf"
        Float(value, exception: false)
      end

      def sum_counter_float(parsed, metric_name)
        entries = parsed[metric_name] || {}
        entries.values.sum.to_f
      end

      def gauge_value(parsed, metric_name)
        entries = parsed[metric_name]
        return nil if entries.nil? || entries.empty?
        entries.values.first.to_f
      end

      def by_label(parsed, metric_name, label_name)
        entries = parsed[metric_name] || {}
        entries.each_with_object({}) do |(labels, value), out|
          label_value = labels[label_name]
          next if label_value.nil?

          out[label_value] = value.to_i
        end
      end

      def by_label_pair(parsed, metric_name, outer_label, inner_label)
        entries = parsed[metric_name] || {}
        entries.each_with_object({}) do |(labels, value), out|
          outer = labels[outer_label]
          inner = labels[inner_label]
          next if outer.nil? || inner.nil?

          out[outer] ||= {}
          out[outer][inner] = value.to_i
        end
      end

      def sum_counter(parsed, metric_name)
        entries = parsed[metric_name] || {}
        entries.values.sum.to_i
      end
    end
  end
end
