# frozen_string_literal: true

require "ffi"
require "json"
require "sqlglot"
require_relative "native_library"

module Upkeep
  module SqlglotSemantics
    class LibraryNotFoundError < Sqlglot::Error; end

    module Native
      extend FFI::Library

      LIB_NAME = "upkeep_sqlglot_semantics"
      SOEXT = FFI::Platform::LIBSUFFIX

      module_function

      def find_library
        override = ENV["UPKEEP_SQLGLOT_SEMANTICS_LIB_PATH"]
        return override if override && File.file?(override)

        gem_root = File.expand_path("../../..", __dir__)
        installed = NativeLibrary.find(__dir__, extensions: [SOEXT])
        return installed if installed

        development = NativeLibrary.find(
          File.join(
            gem_root,
            "ext",
            "upkeep_sqlglot_semantics",
            "target",
            "release"
          ),
          extensions: [SOEXT]
        )
        development || LIB_NAME
      end

      begin
        ffi_lib find_library
      rescue LoadError => error
        raise LibraryNotFoundError,
          "Could not load lib#{LIB_NAME}: #{error.message}. " \
          "Perform a full gem reinstall so the native semantic extension is built."
      end

      attach_function :native_qualify_columns,
        :upkeep_sqlglot_semantics_qualify_columns,
        %i[string string string],
        :pointer
      attach_function :native_build_scope,
        :upkeep_sqlglot_semantics_build_scope,
        [:string],
        :pointer
      attach_function :native_lineage,
        :upkeep_sqlglot_semantics_lineage,
        %i[string string string string],
        :pointer
      attach_function :native_free,
        :upkeep_sqlglot_semantics_free,
        [:pointer],
        :void

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

      def call(pointer)
        raise Sqlglot::Error, "native SQLGlot semantic binding returned null" if pointer.null?

        response = JSON.parse(pointer.read_string)
        raise Sqlglot::Error, response.fetch("error") unless response.fetch("ok")

        response.fetch("result")
      ensure
        native_free(pointer) if pointer && !pointer.null?
      end
      private_class_method :call
    end
  end
end
