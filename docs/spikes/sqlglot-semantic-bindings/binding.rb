# frozen_string_literal: true

require "ffi"
require "json"

module SqlglotSemanticBinding
  extend FFI::Library

  extension = RbConfig::CONFIG.fetch("host_os").include?("darwin") ? "dylib" : "so"
  ffi_lib File.expand_path("target/release/libupkeep_sqlglot_semantic_bindings.#{extension}", __dir__)

  attach_function :native_analyze, :upkeep_sqlglot_analyze, %i[string string string string], :pointer
  attach_function :native_free, :upkeep_sqlglot_free, [:pointer], :void

  module_function

  def analyze(sql, dialect:, schema:, outputs: [])
    pointer = native_analyze(sql, dialect.to_s, JSON.generate(schema), JSON.generate(outputs))
    raise "native binding returned null" if pointer.null?

    result = JSON.parse(pointer.read_string)
    raise ArgumentError, result.fetch("error") unless result.fetch("ok")

    result
  ensure
    native_free(pointer) if defined?(pointer) && pointer && !pointer.null?
  end
end
