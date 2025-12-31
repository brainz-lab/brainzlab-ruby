# frozen_string_literal: true

module BrainzLab
  module Reflex
    class Breadcrumbs
      MAX_BREADCRUMBS = 50

      def initialize
        @breadcrumbs = []
        @mutex = Mutex.new
      end

      def add(message:, category: 'default', level: :info, data: nil)
        crumb = {
          timestamp: Time.now.utc.iso8601(3),
          message: message.to_s,
          category: category.to_s,
          level: level.to_s
        }
        crumb[:data] = data if data

        @mutex.synchronize do
          @breadcrumbs << crumb
          @breadcrumbs.shift if @breadcrumbs.size > MAX_BREADCRUMBS
        end
      end

      def to_a
        @mutex.synchronize { @breadcrumbs.dup }
      end

      def clear!
        @mutex.synchronize { @breadcrumbs.clear }
      end

      def size
        @mutex.synchronize { @breadcrumbs.size }
      end
    end

    class << self
      def breadcrumbs
        Context.current.breadcrumbs
      end

      def add_breadcrumb(message, category: 'default', level: :info, data: nil)
        breadcrumbs.add(message: message, category: category, level: level, data: data)
      end

      def clear_breadcrumbs!
        breadcrumbs.clear!
      end
    end
  end
end
