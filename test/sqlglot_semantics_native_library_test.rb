# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "upkeep/sqlglot/native_library"

class SqlglotSemanticsNativeLibraryTest < Minitest::Test
  def test_finds_unix_prefixed_library
    Dir.mktmpdir do |directory|
      library = File.join(directory, "libsqlglot_rust.so")
      FileUtils.touch(library)

      assert_equal library, Upkeep::SQLGlot::NativeLibrary.find(directory)
    end
  end

  def test_finds_unprefixed_windows_library
    Dir.mktmpdir do |directory|
      library = File.join(directory, "sqlglot_rust.dll")
      FileUtils.touch(library)

      assert_equal library, Upkeep::SQLGlot::NativeLibrary.find(directory)
    end
  end
end
