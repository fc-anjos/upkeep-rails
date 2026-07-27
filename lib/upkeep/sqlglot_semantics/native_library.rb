# frozen_string_literal: true

module Upkeep
  module SqlglotSemantics
    module NativeLibrary
      BASENAME = "upkeep_sqlglot_semantics"
      EXTENSIONS = %w[so dylib dll].freeze

      module_function

      def names(extension)
        ["lib#{BASENAME}.#{extension}", "#{BASENAME}.#{extension}"]
      end

      def find(directory, extensions: EXTENSIONS)
        extensions
          .flat_map { |extension| names(extension) }
          .map { |name| File.join(directory, name) }
          .find { |path| File.file?(path) }
      end
    end
  end
end
