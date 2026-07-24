# frozen_string_literal: true

require "ffi"
require "json"
require "sqlglot"

module Sqlglot
  module Semantics
    class Error < Sqlglot::Error; end
    class LibraryNotFoundError < Error; end

    module Native
      extend FFI::Library

      LIB_NAME = "sqlglot_semantics"
      SOEXT = FFI::Platform::LIBSUFFIX

      module_function

      def find_library
        override = ENV["SQLGLOT_SEMANTICS_LIB_PATH"]
        return override if override && File.file?(override)

        gem_root = File.expand_path("../../..", __dir__)
        candidates = [
          File.join(__dir__, "lib#{LIB_NAME}.#{SOEXT}"),
          File.join(
            gem_root,
            "ext",
            "sqlglot_semantics",
            "target",
            "release",
            "lib#{LIB_NAME}.#{SOEXT}"
          )
        ]
        candidates.find { |candidate| File.file?(candidate) } || LIB_NAME
      end

      begin
        ffi_lib find_library
      rescue LoadError => error
        raise LibraryNotFoundError,
          "Could not load lib#{LIB_NAME}: #{error.message}. " \
          "Perform a full gem reinstall so the native semantic extension is built."
      end

      attach_function :native_qualify_columns,
        :sqlglot_semantics_qualify_columns,
        %i[string string string],
        :pointer
      attach_function :native_build_scope,
        :sqlglot_semantics_build_scope,
        [:string],
        :pointer
      attach_function :native_lineage,
        :sqlglot_semantics_lineage,
        %i[string string string string],
        :pointer
      attach_function :native_version, :sqlglot_semantics_version, [], :string
      attach_function :native_free, :sqlglot_semantics_free, [:pointer], :void

      def qualify_columns(statement, schema)
        call(
          native_qualify_columns(
            JSON.generate(statement),
            JSON.generate(schema.mapping),
            schema.dialect
          )
        )
      end

      def build_scope(statement)
        call(native_build_scope(JSON.generate(statement)))
      end

      def lineage(column, statement, schema, config)
        call(
          native_lineage(
            column.to_s,
            JSON.generate(statement),
            JSON.generate(schema.mapping),
            JSON.generate(config.to_h)
          )
        )
      end

      def version
        native_version()
      end

      def call(pointer)
        raise Error, "native SQLGlot semantic binding returned null" if pointer.null?

        response = JSON.parse(pointer.read_string)
        raise Error, response.fetch("error") unless response.fetch("ok")

        response.fetch("result")
      ensure
        native_free(pointer) if pointer && !pointer.null?
      end
      private_class_method :call
    end
  end
end
