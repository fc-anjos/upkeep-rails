# frozen_string_literal: true

require "digest"
require_relative "manifest_diff"

module Upkeep
  module HerbSupport
    class ManifestCache
      Entry = Data.define(:path, :source_digest, :source, :manifest, :last_update)

      attr_reader :entries

      def initialize
        @entries = {}
      end

      def fetch(path:, source:, parse_options: ManifestDiff::PARSE_OPTIONS)
        source_digest = digest(source)
        entry = entries[path]

        return entry.manifest if entry&.source_digest == source_digest

        update = update_for(path: path, old_source: entry&.source, new_source: source, parse_options: parse_options)
        manifest = update[:new_manifest] || TemplateManifest.build(path: path, source: source, parse_options: parse_options)
        entries[path] = Entry.new(path, source_digest, source.dup, manifest, update_payload(update))

        manifest
      end

      def last_update_for(path)
        entries.fetch(path).last_update
      end

      def summary
        updates = entries.values.map(&:last_update)

        {
          entries: entries.size,
          actions: updates.map { |update| update.fetch(:action) }.tally,
          topology_changes: updates.count { |update| update.fetch(:topology_changed, false) }
        }
      end

      def clear
        entries.clear
      end

      private

      def update_for(path:, old_source:, new_source:, parse_options:)
        return initial_update(path: path, source: new_source, parse_options: parse_options) unless old_source

        ManifestDiff.plan(path: path, old_source: old_source, new_source: new_source, parse_options: parse_options).to_h
      end

      def initial_update(path:, source:, parse_options:)
        manifest = TemplateManifest.build(path: path, source: source, parse_options: parse_options)

        {
          path: path,
          action: "initial_build",
          reason: "new_template",
          topology_changed: true,
          diff_identical: false,
          operation_types: [],
          operations: [],
          new_manifest: manifest,
          new_manifest_fingerprint: manifest.fingerprint,
          stable_topology: false,
          gate_passed: manifest.parse.fetch(:ok)
        }
      end

      def update_payload(update)
        update.reject { |key, _value| %i[old_manifest new_manifest old_topology_signature new_topology_signature].include?(key) }
      end

      def digest(source)
        Digest::SHA256.hexdigest(source)
      end
    end
  end
end
