# frozen_string_literal: true

require "pathname"

module Upkeep
  module HerbLoader
    WORKSPACE_ROOT = Pathname(__dir__).join("../../../..").realpath
    HERB_LIB = WORKSPACE_ROOT.join("rails/view-stack/herb/lib").to_s

    module_function

    def load!
      $LOAD_PATH.unshift(HERB_LIB) unless $LOAD_PATH.include?(HERB_LIB)
      require "herb"
    end
  end
end

Upkeep::HerbLoader.load!
