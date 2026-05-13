# frozen_string_literal: true

require "active_support/notifications"

module Upkeep
  module HerbSupport
    class PerformanceGate
      DEFAULT_BUDGETS = {
        capture_duration_ms: 250.0,
        capture_allocations: 120_000,
        replay_duration_ms: 150.0,
        replay_sql_count: 8,
        graph_nodes: 30,
        graph_edges: 50,
        payload_bytes: 50_000,
        manifest_direct_replay_targets: 1
      }.freeze

      def initialize(budgets: DEFAULT_BUDGETS)
        @budgets = budgets
        @renderer = Rendering::Engine.new
        @selector = Targeting::Selector.new
      end

      def run
        Runtime::Install.call
        Domain::Database.reset!
        Domain::Database.seed!

        initial = nil
        capture = measure { initial = renderer.render_request("boards/collection", method(:relation_request)) }

        Runtime::ChangeLog.reset
        Domain::Card.create!(board: Domain::Board.find_by!(name: "Launch"), title: "Ship", status: "open", position: 4, value: 30)
        changes = Runtime::ChangeLog.events.dup
        full_after = renderer.render_request("boards/collection", method(:relation_request))
        targets = selector.select(initial.recorder, changes)

        replay_payloads = []
        replay = measure_with_sql do
          replay_payloads = targets.map do |target|
            recipe = initial.recorder.graph.node(Targeting::Extraction.frame_id_for(target)).payload.fetch(:recipe)
            html = recipe.render_target(target)
            full_target_html = Targeting::Extraction.extract_target_html(full_after.html, target)

            {
              target: target.to_h,
              bytes: html.bytesize,
              manifest_direct_replay: recipe.manifest_target_render?(target),
              matches_full_target: Targeting::Extraction.normalize_html(html) == Targeting::Extraction.normalize_html(full_target_html)
            }
          end
        end

        metrics = {
          capture_duration_ms: capture.fetch(:duration_ms),
          capture_allocations: capture.fetch(:allocations),
          replay_duration_ms: replay.fetch(:duration_ms),
          replay_sql_count: replay.fetch(:sql_count),
          graph_nodes: initial.recorder.graph.summary.fetch(:nodes),
          graph_edges: initial.recorder.graph.summary.fetch(:edges),
          payload_bytes: replay_payloads.sum { |payload| payload.fetch(:bytes) },
          targets: targets.size,
          manifest_direct_replay_targets: replay_payloads.count { |payload| payload.fetch(:manifest_direct_replay) },
          replay_matches_full_target: replay_payloads.all? { |payload| payload.fetch(:matches_full_target) }
        }

        {
          budgets: budgets,
          metrics: metrics,
          gate_passed: gate_passed?(metrics),
          failures: failures(metrics),
          replay_payloads: replay_payloads
        }
      end

      private

      attr_reader :budgets, :renderer, :selector

      def relation_request
        board = Domain::Board.find_by!(name: "Launch")
        {
          board: board,
          cards: board.cards.order(:position)
        }
      end

      def measure
        before_allocations = GC.stat.fetch(:total_allocated_objects)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        {
          duration_ms: ((finished_at - started_at) * 1000.0).round(3),
          allocations: GC.stat.fetch(:total_allocated_objects) - before_allocations
        }
      end

      def measure_with_sql
        sql_count = 0
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
          sql = payload[:sql].to_s
          sql_count += 1 if sql.start_with?("SELECT")
        end

        measure { yield }.merge(sql_count: sql_count)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end

      def gate_passed?(metrics)
        failures(metrics).empty?
      end

      def failures(metrics)
        failures = []
        failures << "replay_mismatch" unless metrics.fetch(:replay_matches_full_target)

        budgets.each do |metric, budget|
          value = metrics.fetch(metric)
          if metric == :manifest_direct_replay_targets
            failures << "#{metric}_below_budget" if value < budget
          elsif value > budget
            failures << "#{metric}_over_budget"
          end
        end

        failures
      end
    end
  end
end
