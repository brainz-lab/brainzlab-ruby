# frozen_string_literal: true

require_relative "recall/client"
require_relative "recall/buffer"
require_relative "recall/logger"

module BrainzLab
  module Recall
    class << self
      def debug(message, **data)
        log(:debug, message, **data)
      end

      def info(message, **data)
        log(:info, message, **data)
      end

      def warn(message, **data)
        log(:warn, message, **data)
      end

      def error(message, **data)
        log(:error, message, **data)
      end

      def fatal(message, **data)
        log(:fatal, message, **data)
      end

      def log(level, message, **data)
        config = BrainzLab.configuration
        return unless config.recall_enabled
        return unless config.level_enabled?(level)

        entry = build_entry(level, message, data)
        buffer.push(entry)
      end

      def time(label, **data)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

        info("#{label} (#{duration_ms}ms)", **data.merge(duration_ms: duration_ms))
        result
      end

      def flush
        buffer.flush
      end

      def logger(name = nil)
        Logger.new(name)
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def buffer
        @buffer ||= Buffer.new(BrainzLab.configuration, client)
      end

      def reset!
        @client = nil
        @buffer = nil
      end

      private

      def build_entry(level, message, data)
        config = BrainzLab.configuration
        context = Context.current

        entry = {
          timestamp: Time.now.utc.iso8601(3),
          level: level.to_s,
          message: message.to_s
        }

        # Add configuration context
        entry[:environment] = config.environment if config.environment
        entry[:service] = config.service if config.service
        entry[:host] = config.host if config.host
        entry[:commit] = config.commit if config.commit
        entry[:branch] = config.branch if config.branch

        # Add request context
        entry[:request_id] = context.request_id if context.request_id
        entry[:session_id] = context.session_id if context.session_id

        # Merge context data with provided data
        merged_data = context.data_hash.merge(scrub_data(data))
        entry[:data] = merged_data unless merged_data.empty?

        entry
      end

      def scrub_data(data)
        return data if BrainzLab.configuration.scrub_fields.empty?

        scrub_fields = BrainzLab.configuration.scrub_fields
        deep_scrub(data, scrub_fields)
      end

      def deep_scrub(obj, fields)
        case obj
        when Hash
          obj.each_with_object({}) do |(key, value), result|
            if should_scrub?(key, fields)
              result[key] = "[FILTERED]"
            else
              result[key] = deep_scrub(value, fields)
            end
          end
        when Array
          obj.map { |item| deep_scrub(item, fields) }
        else
          obj
        end
      end

      def should_scrub?(key, fields)
        key_str = key.to_s.downcase
        fields.any? do |field|
          case field
          when Regexp
            key_str.match?(field)
          else
            key_str == field.to_s.downcase
          end
        end
      end
    end
  end
end
