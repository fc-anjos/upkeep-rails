# frozen_string_literal: true

module Upkeep
  module SQLGlot
    module NativeLibrary
      BASENAME = "sqlglot_rust"
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
