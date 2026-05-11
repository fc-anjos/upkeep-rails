# frozen_string_literal: true

require "time"

module Upkeep
  module Proofs
    class AuthSurfaces
      REQUIRED_SOURCES = %w[
        Current.user
        active_record_attribute
        active_record_collection
        cookie
        current_attribute
        request
        session
        warden_user
      ].freeze

      def initialize
        @renderer = Rendering::Engine.new
        @selector = Targeting::Selector.new
      end

      def run
        Runtime::Install.call

        case_results = [
          run_case(
            name: "warden_user_update_targets_only_matching_subscriber",
            mutate: -> { Domain::User.find_by!(name: "Alice").update!(name: "Alice Prime") },
            assertions: method(:assert_warden_user_update)
          ),
          run_case(
            name: "auth_value_update_keeps_payloads_partitioned",
            mutate: -> { Domain::Card.find_by!(title: "Plan").update!(value: 90) },
            assertions: method(:assert_value_update_partitioned)
          )
        ]

        {
          generated_at: Time.now.utc.iso8601,
          summary: {
            cases: case_results.size,
            passed: case_results.count { |result| result.fetch(:passed) },
            failed: case_results.count { |result| !result.fetch(:passed) },
            ambient_source_cases: case_results.count { |result| result.fetch(:ambient_sources_present) },
            subscriber_specific_cases: case_results.count { |result| result.fetch(:subscriber_results).any? { |subscriber| subscriber.fetch(:selected_targets).any? } }
          },
          cases: case_results
        }
      end

      private

      attr_reader :renderer, :selector

      def run_case(name:, mutate:, assertions:)
        Domain::Database.reset!
        Domain::Database.seed!

        contexts = subscriber_contexts
        initial = render_subscribers(contexts)
        Runtime::ChangeLog.reset
        mutate.call
        changes = Runtime::ChangeLog.events.dup
        full_after = render_subscribers(contexts)

        subscriber_results = contexts.map do |subscriber_name, context|
          initial_render = initial.fetch(subscriber_name)
          full_render = full_after.fetch(subscriber_name)
          targets = selector.select(initial_render.recorder, changes)
          patches = Targeting::Extraction.patches_from_full_rerender(full_render.html, targets)
          patched_html = Targeting::Patcher.new(initial_render.html).apply(patches)

          {
            subscriber: subscriber_name,
            user_id: context.fetch(:user_id),
            selected_targets: targets.map { |target| target_payload(target, initial_render.recorder) },
            patch_payloads: patches.map { |patch| patch_payload(patch, initial_render.recorder) },
            patched_equals_full: Targeting::Extraction.normalize_html(patched_html) == Targeting::Extraction.normalize_html(full_render.html),
            graph_report: initial_render.recorder.graph.report,
            patched_html: Targeting::Extraction.normalize_html(patched_html)
          }
        end

        assertion_result = assertions.call(subscriber_results)
        ambient_sources_present = subscriber_results.all? { |result| ambient_sources_present?(result.fetch(:graph_report)) }

        {
          name: name,
          passed: subscriber_results.all? { |result| result.fetch(:patched_equals_full) } &&
            assertion_result.fetch(:passed) &&
            ambient_sources_present,
          assertion: assertion_result,
          ambient_sources_present: ambient_sources_present,
          changes: changes,
          subscriber_results: subscriber_results.map { |result| result.reject { |key, _value| key == :patched_html } }
        }
      end

      def subscriber_contexts
        {
          "Alice" => {
            user_id: Domain::User.find_by!(name: "Alice").id,
            session: { tenant_id: "tenant-a" },
            cookies: { theme: "light" },
            request: { subdomain: "alpha" },
            current_attributes: { account_id: "account-a", viewer_role: "manager" }
          },
          "Bob" => {
            user_id: Domain::User.find_by!(name: "Bob").id,
            session: { tenant_id: "tenant-b" },
            cookies: { theme: "dark" },
            request: { subdomain: "beta" },
            current_attributes: { account_id: "account-b", viewer_role: "viewer" }
          }
        }
      end

      def render_subscribers(contexts)
        contexts.transform_values do |context|
          user = Domain::User.find(context.fetch(:user_id))
          renderer.render_request(
            "boards/auth_surfaces",
            method(:auth_request),
            user: user,
            session: context.fetch(:session),
            cookies: context.fetch(:cookies),
            request: context.fetch(:request),
            warden: { user: user },
            current_attributes: context.fetch(:current_attributes)
          )
        end
      end

      def auth_request
        board = Domain::Board.find_by!(name: "Launch")
        {
          board: board,
          cards: board.cards.order(:position)
        }
      end

      def assert_warden_user_update(subscriber_results)
        alice = subscriber_results.find { |result| result.fetch(:subscriber) == "Alice" }
        bob = subscriber_results.find { |result| result.fetch(:subscriber) == "Bob" }

        {
          passed: alice.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "page" } &&
            bob.fetch(:selected_targets).empty? &&
            alice.fetch(:patched_html).include?("Alice Prime") &&
            !bob.fetch(:patched_html).include?("Alice Prime"),
          alice_page_targeted: alice.fetch(:selected_targets).any? { |target| target.fetch(:kind) == "page" },
          bob_not_targeted: bob.fetch(:selected_targets).empty?,
          bob_does_not_receive_alice_name: !bob.fetch(:patched_html).include?("Alice Prime")
        }
      end

      def assert_value_update_partitioned(subscriber_results)
        alice = subscriber_results.find { |result| result.fetch(:subscriber) == "Alice" }
        bob = subscriber_results.find { |result| result.fetch(:subscriber) == "Bob" }

        {
          passed: alice.fetch(:patched_html).include?("$90") &&
            bob.fetch(:patched_html).include?("Hidden") &&
            !bob.fetch(:patched_html).include?("$90") &&
            distinct_fragment_payloads?(subscriber_results),
          alice_sees_changed_value: alice.fetch(:patched_html).include?("$90"),
          bob_does_not_receive_changed_value: !bob.fetch(:patched_html).include?("$90"),
          distinct_fragment_payloads: distinct_fragment_payloads?(subscriber_results)
        }
      end

      def distinct_fragment_payloads?(subscriber_results)
        payloads = subscriber_results.flat_map { |result| result.fetch(:patch_payloads) }
        grouped = payloads.group_by { |payload| [payload.fetch(:kind), payload.fetch(:id)] }
        grouped.any? do |_target_key, target_payloads|
          target_payloads.map { |payload| payload.fetch(:identity_signature) }.uniq.size > 1 &&
            target_payloads.map { |payload| payload.fetch(:html_digest) }.uniq.size > 1
        end
      end

      def ambient_sources_present?(graph_report)
        sources = graph_report.fetch(:summary).fetch(:dependency_sources)
        (REQUIRED_SOURCES - sources).empty?
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
