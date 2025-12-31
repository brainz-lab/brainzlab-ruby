# frozen_string_literal: true

require 'logger'

module BrainzLab
  module Recall
    class Logger < ::Logger
      attr_accessor :broadcast_to

      def initialize(service_name = nil, broadcast_to: nil)
        super(nil)
        @service_name = service_name
        @broadcast_to = broadcast_to
        @level = ::Logger::DEBUG
        @formatter = proc { |_severity, _time, _progname, msg| msg }
      end

      def add(severity, message = nil, progname = nil)
        severity ||= ::Logger::UNKNOWN

        # Handle block-based messages
        message = yield if message.nil? && block_given?

        # Handle progname as message (standard Logger behavior)
        if message.nil?
          message = progname
          progname = nil
        end

        # Broadcast to original logger if configured
        @broadcast_to&.add(severity, message, progname)

        # Skip if below configured level
        return true if severity < @level

        level = severity_to_level(severity)
        return true unless BrainzLab.configuration.level_enabled?(level)

        # Extract structured data if message is a hash
        data = {}
        if message.is_a?(Hash)
          data = message.dup
          message = data.delete(:message) || data.delete(:msg) || data.to_s
        end

        data[:service] = @service_name if @service_name
        data[:progname] = progname if progname

        Recall.log(level, message.to_s, **data)
        true
      end

      def debug(message = nil, &)
        add(::Logger::DEBUG, message, &)
      end

      def info(message = nil, &)
        add(::Logger::INFO, message, &)
      end

      def warn(message = nil, &)
        add(::Logger::WARN, message, &)
      end

      def error(message = nil, &)
        add(::Logger::ERROR, message, &)
      end

      def fatal(message = nil, &)
        add(::Logger::FATAL, message, &)
      end

      def unknown(message = nil, &)
        add(::Logger::UNKNOWN, message, &)
      end

      # Rails compatibility methods
      def silence(severity = ::Logger::ERROR)
        old_level = @level
        @level = severity
        yield self
      ensure
        @level = old_level
      end

      def tagged(*tags)
        if block_given?
          BrainzLab.with_context(tags: tags) { yield self }
        else
          self
        end
      end

      def flush
        Recall.flush
      end

      def close
        flush
      end

      private

      def severity_to_level(severity)
        case severity
        when ::Logger::DEBUG then :debug
        when ::Logger::INFO then :info
        when ::Logger::WARN then :warn
        when ::Logger::ERROR then :error
        when ::Logger::FATAL, ::Logger::UNKNOWN then :fatal
        else :info
        end
      end
    end
  end
end
