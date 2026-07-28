# frozen_string_literal: true

require "ffi"
require_relative "native_library"

module Upkeep
  module SQLGlot
    module Native
      extend FFI::Library

      LIB_NAME = "sqlglot_rust"
      SOEXT = FFI::Platform::LIBSUFFIX

      module_function

      def find_library
        override = ENV["UPKEEP_SQLGLOT_LIB_PATH"]
        return override if override && File.file?(override)

        gem_root = File.expand_path("../../..", __dir__)
        installed = NativeLibrary.find(__dir__, extensions: [SOEXT])
        return installed if installed

        development = NativeLibrary.find(
          File.join(
            gem_root,
            "ext",
            "sqlglot_rust",
            "sql-glot-rust",
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
          "Perform a full gem reinstall so Upkeep's native library is present."
      end

      attach_function :sqlglot_parse, %i[string string], :pointer
      attach_function :sqlglot_transpile, %i[string string string], :pointer
      attach_function :sqlglot_generate, %i[string string], :pointer
      attach_function :sqlglot_version, [], :string
      attach_function :sqlglot_qualify_columns,
        %i[string string string],
        :pointer
      attach_function :sqlglot_build_scope, [:string], :pointer
      attach_function :sqlglot_lineage,
        %i[string string string string],
        :pointer
      attach_function :sqlglot_free, [:pointer], :void

      def parse(sql, dialect)
        read_owned(
          sqlglot_parse(sql, dialect),
          ParseError,
          "Failed to parse SQL: #{sql.inspect}"
        )
      end

      def transpile(sql, from_dialect, to_dialect)
        read_owned(
          sqlglot_transpile(sql, from_dialect, to_dialect),
          TranspileError,
          "Failed to transpile SQL: #{sql.inspect}"
        )
      end

      def generate(statement_json, dialect)
        read_owned(
          sqlglot_generate(statement_json, dialect),
          GenerateError,
          "Failed to generate SQL from AST"
        )
      end

      def version
        sqlglot_version
      end

      def qualify_columns(statement_json, schema_json, dialect)
        read_owned(
          sqlglot_qualify_columns(statement_json, schema_json, dialect),
          SemanticError,
          "Failed to qualify SQLGlot columns"
        )
      end

      def build_scope(statement_json)
        read_owned(
          sqlglot_build_scope(statement_json),
          SemanticError,
          "Failed to build SQLGlot scope"
        )
      end

      def lineage(column, statement_json, schema_json, config_json)
        read_owned(
          sqlglot_lineage(column, statement_json, schema_json, config_json),
          SemanticError,
          "Failed to build SQLGlot lineage for #{column.inspect}"
        )
      end

      def read_owned(pointer, error_class, message)
        raise error_class, message if pointer.null?

        pointer.read_string.force_encoding(Encoding::UTF_8)
      ensure
        sqlglot_free(pointer) if pointer && !pointer.null?
      end
      private_class_method :read_owned
    end
  end
end
