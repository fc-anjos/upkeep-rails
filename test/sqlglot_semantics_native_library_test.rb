# frozen_string_literal: true

require "fileutils"
require "test_helper"
require "tmpdir"
require "upkeep/sqlglot_semantics/native_library"

class SqlglotSemanticsNativeLibraryTest < Minitest::Test
  def test_finds_unix_prefixed_library
    Dir.mktmpdir do |directory|
      library = File.join(directory, "libupkeep_sqlglot_semantics.so")
      FileUtils.touch(library)

      assert_equal library, Upkeep::SqlglotSemantics::NativeLibrary.find(directory)
    end
  end

  def test_finds_unprefixed_windows_library
    Dir.mktmpdir do |directory|
      library = File.join(directory, "upkeep_sqlglot_semantics.dll")
      FileUtils.touch(library)

      assert_equal library, Upkeep::SqlglotSemantics::NativeLibrary.find(directory)
    end
  end
end
