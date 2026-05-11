# frozen_string_literal: true

module Upkeep
  module Rails
    class Configuration
      attr_accessor :enabled

      def initialize
        @enabled = true
      end
    end
  end
end
