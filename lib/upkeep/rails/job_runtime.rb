# frozen_string_literal: true

require "active_support/concern"

module Upkeep
  module Rails
    module JobRuntime
      extend ActiveSupport::Concern

      included do
        around_perform :upkeep_capture_job
      end

      module_function

      def install
        return if @installed
        return unless defined?(::ActiveJob::Base)

        ::ActiveJob::Base.include(self)
        @installed = true
      end

      def installed?
        !!@installed
      end

      def reset!
        @installed = false
      end

      private

      def upkeep_capture_job
        return yield if Upkeep::Runtime::ChangeLog.capturing?

        result, changes = Upkeep::Runtime::ChangeLog.capture { yield }
        Upkeep::Rails.deliver_changes!(changes)
        result
      end
    end
  end
end
