# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require_relative "../../lib/upkeep/sqlglot/native_library"

RUST_REPOSITORY = "https://github.com/protegrity/sql-glot-rust.git"
RUST_TAG = "v0.10.26"

extension_dir = __dir__
gem_root = File.expand_path("../..", extension_dir)
source_dir = File.join(extension_dir, "sql-glot-rust")
library_dir = File.join(gem_root, "lib", "upkeep", "sqlglot")

host_os = RbConfig::CONFIG.fetch("host_os")
extension = if host_os.match?(/darwin/)
  "dylib"
elsif host_os.match?(/mswin|mingw/)
  "dll"
else
  "so"
end

packaged_library = Upkeep::SQLGlot::NativeLibrary.find(
  library_dir,
  extensions: [extension]
)

unless packaged_library
  abort "ERROR: cargo is required to build SQLGlot" unless system(
    "cargo",
    "--version",
    out: File::NULL
  )
  abort "ERROR: git is required to fetch SQLGlot" unless system(
    "git",
    "--version",
    out: File::NULL
  )

  unless Dir.exist?(source_dir)
    success = system(
      "git",
      "clone",
      "--depth",
      "1",
      "--branch",
      RUST_TAG,
      RUST_REPOSITORY,
      source_dir
    )
    abort "ERROR: SQLGlot source checkout failed" unless success
  end

  source_tag = IO.popen(
    ["git", "-C", source_dir, "describe", "--tags", "--exact-match", "HEAD"],
    &:read
  ).strip
  abort "ERROR: expected SQLGlot #{RUST_TAG}, found #{source_tag}" unless source_tag == RUST_TAG

  success = system(
    "cargo",
    "build",
    "--release",
    "--manifest-path",
    File.join(source_dir, "Cargo.toml")
  )
  abort "ERROR: SQLGlot native build failed" unless success

  built_library = Upkeep::SQLGlot::NativeLibrary.find(
    File.join(source_dir, "target", "release"),
    extensions: [extension]
  )
  abort "ERROR: SQLGlot native library was not produced" unless built_library

  FileUtils.mkdir_p(library_dir)
  FileUtils.cp(built_library, library_dir)
end

File.write(
  File.join(extension_dir, "Makefile"),
  "all:\ninstall:\nclean:\n"
)
