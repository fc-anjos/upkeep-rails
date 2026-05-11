# frozen_string_literal: true

require "time"

module Upkeep
  module Proofs
    class EndToEnd
      def initialize
        @renderer = Rendering::Engine.new
        @selector = Targeting::Selector.new
      end

      def run
        Runtime::Install.call

        case_results = cases.map { |test_case| run_case(test_case) }

        {
          generated_at: Time.now.utc.iso8601,
          summary: {
            cases: case_results.size,
            passed: case_results.count { |result| result.fetch(:passed) },
            failed: case_results.count { |result| !result.fetch(:passed) },
            narrow_fragment_cases: case_results.count { |result| result.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "fragment" } },
            render_site_cases: case_results.count { |result| result.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "render_site" } },
            page_fallback_cases: case_results.count { |result| result.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "page" } }
          },
          cases: case_results
        }
      end

      private

      attr_reader :renderer, :selector

      def cases
        [
          {
            name: "easy_partial_record_update",
            template: "boards/collection",
            request: method(:relation_request),
            mutate: -> { Domain::Card.find_by!(title: "Plan").update!(title: "Plan v2") },
            expected_strategy: "fragment"
          },
          {
            name: "hard_presenter_helper_record_update",
            template: "boards/collection",
            request: method(:relation_request),
            mutate: -> { Domain::Card.find_by!(title: "Plan").update!(status: "done") },
            expected_strategy: "fragment"
          },
          {
            name: "hard_collection_membership_create",
            template: "boards/collection",
            request: method(:relation_request),
            mutate: -> { Domain::Card.create!(board: Domain::Board.find_by!(name: "Launch"), title: "Ship", status: "open", position: 4, value: 30) },
            expected_strategy: "render_site"
          },
          {
            name: "hard_inline_page_without_partials",
            template: "boards/inline",
            request: method(:relation_request),
            mutate: -> { Domain::Card.find_by!(title: "Build").update!(title: "Build v2") },
            expected_strategy: "page"
          },
          {
            name: "hard_helper_hidden_collection_create",
            template: "boards/helper_hidden",
            request: method(:relation_request),
            mutate: -> { Domain::Card.create!(board: Domain::Board.find_by!(name: "Launch"), title: "Hidden", status: "open", position: 4, value: 30) },
            expected_strategy: "page"
          },
          {
            name: "hard_preloaded_plain_data",
            template: "boards/preloaded_plain",
            request: method(:preloaded_plain_request),
            mutate: -> { Domain::Card.find_by!(title: "Build").update!(title: "Build v2") },
            expected_strategy: "page"
          }
        ]
      end

      def run_case(test_case)
        Domain::Database.reset!
        Domain::Database.seed!

        initial = renderer.render_request(test_case.fetch(:template), test_case.fetch(:request))
        Runtime::ChangeLog.reset
        test_case.fetch(:mutate).call
        changes = Runtime::ChangeLog.events.dup
        full_after = renderer.render_request(test_case.fetch(:template), test_case.fetch(:request))

        targets = selector.select(initial.recorder, changes)
        patches = Targeting::Extraction.patches_from_full_rerender(full_after.html, targets)
        patched_html = Targeting::Patcher.new(initial.html).apply(patches)

        normalized_patched = Targeting::Extraction.normalize_html(patched_html)
        normalized_full = Targeting::Extraction.normalize_html(full_after.html)
        selected_kinds = targets.map(&:kind).uniq

        {
          name: test_case.fetch(:name),
          expected_strategy: test_case.fetch(:expected_strategy),
          passed: normalized_patched == normalized_full && selected_kinds.include?(test_case.fetch(:expected_strategy)),
          selected_targets: targets.map { |target| target_payload(target) },
          changes: changes,
          frames_observed: initial.recorder.events_by_frame.transform_values(&:size),
          request_events_observed: initial.recorder.request_events.size,
          graph_summary: initial.recorder.graph.summary,
          initial_html_digest: Targeting::Extraction.digest_html(patched_html),
          full_after_html_digest: Targeting::Extraction.digest_html(full_after.html)
        }
      end

      def relation_request
        board = Domain::Board.find_by!(name: "Launch")
        {
          board: board,
          cards: board.cards.order(:position)
        }
      end

      def preloaded_plain_request
        board = Domain::Board.find_by!(name: "Launch")
        summaries = board.cards.order(:position).map { |card| Domain::CardSummary.new(card.id, card.title) }
        {
          board: board,
          summaries: summaries
        }
      end

      def target_payload(target)
        { kind: target.kind, id: target.id, reason: target.reason }
      end
    end
  end
end
