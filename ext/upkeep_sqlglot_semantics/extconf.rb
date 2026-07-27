# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "../../lib/upkeep/sqlglot_semantics/native_library"

extension_dir = __dir__
gem_root = File.expand_path("../..", extension_dir)
manifest = File.join(extension_dir, "Cargo.toml")
target_dir = File.join(extension_dir, "target", "release")
library_dir = File.join(gem_root, "lib", "upkeep", "sqlglot_semantics")

host_os = RbConfig::CONFIG.fetch("host_os")
extension = if host_os.match?(/darwin/)
  "dylib"
elsif host_os.match?(/mswin|mingw/)
  "dll"
else
  "so"
end
packaged_library = Upkeep::SqlglotSemantics::NativeLibrary.find(
  library_dir,
  extensions: [extension]
)
source_files = Dir[
  File.join(extension_dir, "Cargo.{toml,lock}"),
  File.join(extension_dir, "src", "**", "*.rs")
]
source_changed = packaged_library &&
  source_files.any? { |source| File.mtime(source) > File.mtime(packaged_library) }

unless packaged_library && !source_changed
  abort "ERROR: cargo is required to build Upkeep's SQLGlot semantics" unless system("cargo", "--version", out: File::NULL)

  success = system("cargo", "build", "--release", "--manifest-path", manifest)
  abort "ERROR: Upkeep SQLGlot semantic native build failed" unless success

  built_library = Upkeep::SqlglotSemantics::NativeLibrary.find(
    target_dir,
    extensions: [extension]
  )
  abort "ERROR: native library was not produced in #{target_dir}" unless built_library

  FileUtils.mkdir_p(library_dir)
  FileUtils.cp(built_library, library_dir)
end

File.write(
  File.join(extension_dir, "Makefile"),
  "all:\ninstall:\nclean:\n"
)
