# frozen_string_literal: true

require "time"

module Upkeep
  module Proofs
    class EndToEnd
      def initialize
        @renderer = Rendering::Engine.new
        @selector = Targeting::Selector.new
        @manifests = HerbSupport::RuntimeAlignment.build_manifests(Templates::REGISTRY.values)
        @runtime_alignment = HerbSupport::RuntimeAlignment.new(
          manifests: manifests
        )
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
            page_fallback_cases: case_results.count { |result| result.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "page" } },
            page_fallback_reasons: page_fallback_reasons(case_results),
            unexplained_page_fallback_cases: unexplained_page_fallback_cases(case_results),
            manifest_alignment_passed: case_results.count { |result| result.fetch(:manifest_alignment).fetch(:summary).fetch(:gate_passed) },
            manifest_alignment_failed: case_results.count { |result| !result.fetch(:manifest_alignment).fetch(:summary).fetch(:gate_passed) }
          },
          cases: case_results
        }
      end

      private

      attr_reader :renderer, :selector, :manifests, :runtime_alignment

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
        manifest_alignment = runtime_alignment.report(graph: initial.recorder.graph, selected_targets: targets)
        fallback_analyzer = HerbSupport::FallbackAnalyzer.new(manifests: manifests, alignment_report: manifest_alignment)
        patches = Targeting::Extraction.patches_from_full_rerender(full_after.html, targets)
        patched_html = Targeting::Patcher.new(initial.html).apply(patches)
        target_replay_results = replay_results(initial.recorder, targets, full_after.html)

        normalized_patched = Targeting::Extraction.normalize_html(patched_html)
        normalized_full = Targeting::Extraction.normalize_html(full_after.html)
        selected_kinds = targets.map(&:kind).uniq

        {
          name: test_case.fetch(:name),
          expected_strategy: test_case.fetch(:expected_strategy),
          passed: normalized_patched == normalized_full &&
            selected_kinds.include?(test_case.fetch(:expected_strategy)) &&
            target_replay_results.all? { |result| result.fetch(:matches_full_target) },
          selected_targets: targets.map { |target| target_payload(target, initial.recorder.graph, changes, fallback_analyzer) },
          replay_results: target_replay_results,
          manifest_alignment: manifest_alignment,
          changes: changes,
          graph_report: initial.recorder.graph.report,
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

      def page_fallback_reasons(case_results)
        case_results.flat_map do |result|
          result.fetch(:selected_targets).filter_map { |target| target[:fallback_reason] if target.fetch(:kind) == "page" }
        end.tally
      end

      def unexplained_page_fallback_cases(case_results)
        case_results.count do |result|
          result.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "page" && !target[:fallback_reason] }
        end
      end

      def target_payload(target, graph, changes, fallback_analyzer)
        fallback_analyzer.target_payload(graph: graph, target: target, changes: changes)
      end

      def replay_target_payload(target)
        { kind: target.kind, id: target.id, reason: target.reason }
      end

      def replay_results(recorder, targets, full_html)
        targets.map do |target|
          frame_id = Targeting::Extraction.frame_id_for(target)
          recipe = recorder.graph.node(frame_id).payload[:recipe]
          replay_target_html = recipe&.render_target(target)
          full_target_html = Targeting::Extraction.extract_target_html(full_html, target)

          {
            target: replay_target_payload(target),
            recipe: recipe&.to_h,
            manifest_direct_replay: recipe&.manifest_target_render?(target),
            replay_html_digest: replay_target_html ? Targeting::Extraction.digest_html(replay_target_html) : nil,
            full_target_html_digest: Targeting::Extraction.digest_html(full_target_html),
            matches_full_target: replay_target_html &&
              Targeting::Extraction.normalize_html(replay_target_html) == Targeting::Extraction.normalize_html(full_target_html)
          }
        end
      end
    end
  end
end
