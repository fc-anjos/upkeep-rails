# frozen_string_literal: true

require "time"

module Upkeep
  module Proofs
    class IdentitySafety
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
            distinct_identity_payload_cases: case_results.count { |result| result.fetch(:distinct_identity_payloads) },
            subscriber_specific_cases: case_results.count { |result| result.fetch(:subscriber_results).any? { |subscriber| subscriber.fetch(:selected_targets).any? } }
          },
          cases: case_results
        }
      end

      private

      attr_reader :renderer, :selector

      def cases
        [
          {
            name: "identity_card_value_update_does_not_cross_deliver",
            template: "boards/identity_collection",
            request: method(:identity_request),
            mutate: -> { Domain::Card.find_by!(title: "Plan").update!(value: 90) },
            assertions: method(:assert_value_update_no_leak)
          },
          {
            name: "identity_user_limit_update_targets_only_that_user",
            template: "boards/identity_collection",
            request: method(:identity_request),
            mutate: -> { Domain::User.find_by!(name: "Bob").update!(value_limit: 100) },
            assertions: method(:assert_user_limit_update_targets_only_bob)
          },
          {
            name: "identity_visible_collection_membership_is_bucketed",
            template: "boards/identity_visible_collection",
            request: method(:identity_request),
            mutate: -> { Domain::Card.find_by!(title: "Plan").update!(value: 45) },
            assertions: method(:assert_visible_collection_bucketed)
          }
        ]
      end

      def run_case(test_case)
        Domain::Database.reset!
        Domain::Database.seed!

        subscribers = subscriber_users
        initial = render_subscribers(test_case, subscribers)
        Runtime::ChangeLog.reset
        test_case.fetch(:mutate).call
        changes = Runtime::ChangeLog.events.dup
        full_after = render_subscribers(test_case, subscribers)

        subscriber_results = subscribers.map do |subscriber_name, user|
          initial_render = initial.fetch(subscriber_name)
          full_render = full_after.fetch(subscriber_name)
          targets = selector.select(initial_render.recorder, changes)
          patches = Targeting::Extraction.patches_from_full_rerender(full_render.html, targets)
          patched_html = Targeting::Patcher.new(initial_render.html).apply(patches)

          {
            subscriber: subscriber_name,
            user_id: user.id,
            value_limit: user.reload.value_limit,
            selected_targets: targets.map { |target| target_payload(target, initial_render.recorder) },
            patch_payloads: patches.map { |patch| patch_payload(patch, initial_render.recorder) },
            patched_equals_full: Targeting::Extraction.normalize_html(patched_html) == Targeting::Extraction.normalize_html(full_render.html),
            graph_report: initial_render.recorder.graph.report,
            patched_html: Targeting::Extraction.normalize_html(patched_html)
          }
        end

        assertion_result = test_case.fetch(:assertions).call(subscriber_results)

        {
          name: test_case.fetch(:name),
          passed: subscriber_results.all? { |result| result.fetch(:patched_equals_full) } && assertion_result.fetch(:passed),
          assertion: assertion_result,
          distinct_identity_payloads: distinct_identity_payloads?(subscriber_results),
          changes: changes,
          subscriber_results: subscriber_results.map { |result| result.reject { |key, _value| key == :patched_html } }
        }
      end

      def subscriber_users
        {
          "Alice" => Domain::User.find_by!(name: "Alice"),
          "Bob" => Domain::User.find_by!(name: "Bob")
        }
      end

      def render_subscribers(test_case, subscribers)
        subscribers.transform_values do |user|
          renderer.render_request(test_case.fetch(:template), test_case.fetch(:request), user: Domain::User.find(user.id))
        end
      end

      def identity_request
        board = Domain::Board.find_by!(name: "Launch")
        {
          board: board,
          cards: board.cards.order(:position)
        }
      end

      def assert_value_update_no_leak(subscriber_results)
        alice = subscriber_results.find { |result| result.fetch(:subscriber) == "Alice" }
        bob = subscriber_results.find { |result| result.fetch(:subscriber) == "Bob" }

        alice_html = alice.fetch(:patched_html)
        bob_html = bob.fetch(:patched_html)

        {
          passed: alice_html.include?("$90") && bob_html.include?("Hidden") && !bob_html.include?("$90"),
          alice_sees_changed_value: alice_html.include?("$90"),
          bob_does_not_receive_changed_value: !bob_html.include?("$90"),
          naive_shared_payload_would_leak: alice.fetch(:patch_payloads).any? { |payload| payload.fetch(:html).include?("$90") } &&
            bob.fetch(:selected_targets).map { |target| target.fetch(:id) }.intersect?(alice.fetch(:selected_targets).map { |target| target.fetch(:id) })
        }
      end

      def assert_user_limit_update_targets_only_bob(subscriber_results)
        alice = subscriber_results.find { |result| result.fetch(:subscriber) == "Alice" }
        bob = subscriber_results.find { |result| result.fetch(:subscriber) == "Bob" }

        {
          passed: alice.fetch(:selected_targets).empty? && bob.fetch(:selected_targets).any? && bob.fetch(:patched_html).include?("$80"),
          alice_not_targeted: alice.fetch(:selected_targets).empty?,
          bob_targeted: bob.fetch(:selected_targets).any?,
          bob_sees_value_after_limit_change: bob.fetch(:patched_html).include?("$80")
        }
      end

      def assert_visible_collection_bucketed(subscriber_results)
        alice = subscriber_results.find { |result| result.fetch(:subscriber) == "Alice" }
        bob = subscriber_results.find { |result| result.fetch(:subscriber) == "Bob" }

        {
          passed: alice.fetch(:patched_html).include?("Plan") && bob.fetch(:patched_html).include?("Plan") &&
            alice.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "render_site" } &&
            bob.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "render_site" },
          alice_render_site_targeted: alice.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "render_site" },
          bob_render_site_targeted: bob.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "render_site" }
        }
      end

      def distinct_identity_payloads?(subscriber_results)
        payloads = subscriber_results.flat_map { |result| result.fetch(:patch_payloads) }
        grouped = payloads.group_by { |payload| [payload.fetch(:kind), payload.fetch(:id)] }
        grouped.any? do |_target_key, target_payloads|
          target_payloads.map { |payload| payload.fetch(:identity_signature) }.uniq.size > 1 &&
            target_payloads.map { |payload| payload.fetch(:html_digest) }.uniq.size > 1
        end
      end

      def target_payload(target, recorder)
        frame_id = Targeting::Extraction.frame_id_for(target)
        {
          kind: target.kind,
          id: target.id,
          reason: target.reason,
          identity_signature: recorder.identity_signature(frame_id),
          identity_profile: recorder.identity_profile(frame_id)
        }
      end

      def patch_payload(patch, recorder)
        frame_id = Targeting::Extraction.frame_id_for(patch.target)
        {
          kind: patch.target.kind,
          id: patch.target.id,
          identity_signature: recorder.identity_signature(frame_id),
          html_digest: Targeting::Extraction.digest_html(patch.html),
          html: patch.html
        }
      end
    end
  end
end
