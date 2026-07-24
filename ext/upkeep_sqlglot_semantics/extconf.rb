# frozen_string_literal: true

require "fileutils"
require "rbconfig"

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
library_name = "libupkeep_sqlglot_semantics.#{extension}"
packaged_library = File.join(library_dir, library_name)
source_files = Dir[
  File.join(extension_dir, "Cargo.{toml,lock}"),
  File.join(extension_dir, "src", "**", "*.rs")
]
source_changed = File.file?(packaged_library) &&
  source_files.any? { |source| File.mtime(source) > File.mtime(packaged_library) }

unless File.file?(packaged_library) && !source_changed
  abort "ERROR: cargo is required to build Upkeep's SQLGlot semantics" unless system("cargo", "--version", out: File::NULL)

  success = system("cargo", "build", "--release", "--manifest-path", manifest)
  abort "ERROR: Upkeep SQLGlot semantic native build failed" unless success

  built_library = File.join(target_dir, library_name)
  abort "ERROR: native library was not produced at #{built_library}" unless File.file?(built_library)

  FileUtils.mkdir_p(library_dir)
  FileUtils.cp(built_library, packaged_library)
end

File.write(
  File.join(extension_dir, "Makefile"),
  "all:\ninstall:\nclean:\n"
)
