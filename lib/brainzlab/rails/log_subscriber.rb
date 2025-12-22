# frozen_string_literal: true

require "active_support/log_subscriber"

module BrainzLab
  module Rails
    class LogSubscriber < ActiveSupport::LogSubscriber
      INTERNAL_PARAMS = %w[controller action format _method authenticity_token].freeze

      class << self
        attr_accessor :formatter
      end

      def start_processing(event)
        return unless formatter

        request_id = event.payload[:request]&.request_id || Thread.current[:brainzlab_request_id]
        return unless request_id

        payload = event.payload
        params = payload[:params]&.except(*INTERNAL_PARAMS) || {}

        formatter.start_request(request_id,
          method: payload[:method],
          path: payload[:path],
          params: filter_params(params),
          controller: payload[:controller],
          action: payload[:action]
        )
      end

      def process_action(event)
        return unless formatter

        request_id = event.payload[:request]&.request_id || Thread.current[:brainzlab_request_id]
        return unless request_id

        payload = event.payload

        formatter.process_action(request_id,
          controller: payload[:controller],
          action: payload[:action],
          status: payload[:status],
          duration: event.duration,
          view_runtime: payload[:view_runtime],
          db_runtime: payload[:db_runtime]
        )

        # Handle exception if present
        if payload[:exception_object]
          formatter.error(request_id, payload[:exception_object])
        end

        # Output the formatted log
        output = formatter.end_request(request_id)
        log_output(output) if output
      end

      def halted_callback(event)
        # Request was halted by a before_action
      end

      def redirect_to(event)
        # Redirect happened
      end

      private

      def formatter
        self.class.formatter
      end

      def filter_params(params)
        return {} unless params.is_a?(Hash)

        filter_keys = BrainzLab.configuration.scrub_fields.map(&:to_s)
        deep_filter(params, filter_keys)
      end

      def deep_filter(obj, filter_keys)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), h|
            if filter_keys.include?(k.to_s.downcase)
              h[k] = "[FILTERED]"
            else
              h[k] = deep_filter(v, filter_keys)
            end
          end
        when Array
          obj.map { |v| deep_filter(v, filter_keys) }
        else
          obj
        end
      end

      def log_output(output)
        # Output directly to stdout for clean formatting
        # This bypasses the Rails logger which would add timestamps/prefixes
        $stdout.write(output)
      end
    end

    # SQL query subscriber to track query details
    class SqlLogSubscriber < ActiveSupport::LogSubscriber
      IGNORED_PAYLOADS = %w[SCHEMA].freeze

      def sql(event)
        return unless LogSubscriber.formatter

        payload = event.payload
        return if IGNORED_PAYLOADS.include?(payload[:name])

        request_id = Thread.current[:brainzlab_request_id]
        return unless request_id

        # Extract source location from the backtrace
        source = extract_source_location(caller)

        # Normalize SQL for pattern detection (remove specific values)
        sql_pattern = normalize_sql(payload[:sql])

        LogSubscriber.formatter.sql_query(request_id,
          name: payload[:name],
          duration: event.duration,
          sql: payload[:sql],
          sql_pattern: sql_pattern,
          cached: payload[:cached] || payload[:name] == "CACHE",
          source: source
        )
      end

      private

      def extract_source_location(backtrace)
        # Find the first line that's in app/ directory
        backtrace.each do |line|
          if line.include?("/app/") && !line.include?("/brainzlab")
            # Extract just the relevant part: app/models/user.rb:42
            match = line.match(%r{(app/[^:]+:\d+)})
            return match[1] if match
          end
        end
        nil
      end

      def normalize_sql(sql)
        return nil unless sql

        sql
          .gsub(/\b\d+\b/, "?")                    # Replace numbers
          .gsub(/'[^']*'/, "?")                    # Replace strings
          .gsub(/"[^"]*"/, "?")                    # Replace double-quoted strings
          .gsub(/\$\d+/, "?")                      # Replace positional params
          .gsub(/\/\*.*?\*\//, "")                 # Remove comments
          .gsub(/\s+/, " ")                        # Normalize whitespace
          .strip
      end
    end

    # View rendering subscriber
    class ViewLogSubscriber < ActiveSupport::LogSubscriber
      def render_template(event)
        return unless LogSubscriber.formatter

        request_id = Thread.current[:brainzlab_request_id]
        return unless request_id

        payload = event.payload
        template = template_name(payload[:identifier])

        LogSubscriber.formatter.render_template(request_id,
          template: template,
          duration: event.duration,
          layout: payload[:layout]
        )
      end

      def render_partial(event)
        return unless LogSubscriber.formatter

        request_id = Thread.current[:brainzlab_request_id]
        return unless request_id

        payload = event.payload
        template = template_name(payload[:identifier])

        LogSubscriber.formatter.render_partial(request_id,
          template: template,
          duration: event.duration,
          count: payload[:count]
        )
      end

      def render_layout(event)
        return unless LogSubscriber.formatter

        request_id = Thread.current[:brainzlab_request_id]
        return unless request_id

        payload = event.payload
        layout = template_name(payload[:identifier])

        LogSubscriber.formatter.render_layout(request_id,
          layout: layout,
          duration: event.duration
        )
      end

      private

      def template_name(identifier)
        return nil unless identifier

        # Extract relative path from full identifier
        if identifier.include?("/app/views/")
          identifier.split("/app/views/").last
        elsif identifier.include?("/views/")
          identifier.split("/views/").last
        else
          File.basename(identifier)
        end
      end
    end
  end
end
