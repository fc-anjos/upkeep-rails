# frozen_string_literal: true

module Upkeep
  module Benchmark
    class PromParse
      def self.parse(body)
        out = Hash.new { |h, k| h[k] = {} }
        body.each_line do |line|
          line = line.strip
          next if line.empty?
          next if line.start_with?("#")

          name, labels_str, value = split_line(line)
          next if name.nil?

          labels = parse_labels(labels_str)
          out[name][labels] = Float(value)
        end
        out
      end

      def self.split_line(line)
        if (m = line.match(/\A([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)\z/))
          [ m[1], m[2], m[3] ]
        end
      end

      def self.parse_labels(raw)
        return {} if raw.nil? || raw == "{}" || raw.empty?

        inner = raw[1..-2]
        pairs = inner.scan(/([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"\\])*)"/)
        pairs.each_with_object({}) { |(k, v), h| h[k] = v.gsub(/\\(.)/, '\1') }
      end
    end
  end
end
