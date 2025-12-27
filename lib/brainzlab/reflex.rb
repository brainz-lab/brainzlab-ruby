# frozen_string_literal: true

require_relative "reflex/client"
require_relative "reflex/breadcrumbs"
require_relative "reflex/provisioner"

module BrainzLab
  module Reflex
    FILTERED_PARAMS = %w[password password_confirmation token api_key secret credit_card cvv ssn].freeze

    class << self
      def capture(exception, **context)
        return unless enabled?
        return if capture_disabled?
        return if excluded?(exception)
        return if sampled_out?

        # Auto-provision project on first capture if app_name is configured
        ensure_provisioned!

        return unless BrainzLab.configuration.reflex_valid?

        payload = build_payload(exception, context)
        payload = run_before_send(payload, exception)
        return if payload.nil?

        client.send_error(payload)
      end

      def capture_message(message, level: :error, **context)
        return unless enabled?
        return if capture_disabled?
        return if sampled_out?

        # Auto-provision project on first capture if app_name is configured
        ensure_provisioned!

        return unless BrainzLab.configuration.reflex_valid?

        payload = build_message_payload(message, level, context)
        payload = run_before_send(payload, nil)
        return if payload.nil?

        client.send_error(payload)
      end

      def ensure_provisioned!
        return if @provisioned

        @provisioned = true
        provisioner.ensure_project!
      end

      def provisioner
        @provisioner ||= Provisioner.new(BrainzLab.configuration)
      end

      # Temporarily disable capture within a block
      def without_capture
        previous = Thread.current[:brainzlab_capture_disabled]
        Thread.current[:brainzlab_capture_disabled] = true
        yield
      ensure
        Thread.current[:brainzlab_capture_disabled] = previous
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def reset!
        @client = nil
        @provisioner = nil
        @provisioned = false
      end

      private

      def enabled?
        BrainzLab.configuration.reflex_effectively_enabled?
      end

      def capture_disabled?
        Thread.current[:brainzlab_capture_disabled] == true
      end

      def excluded?(exception)
        config = BrainzLab.configuration
        config.reflex_excluded_exceptions.any? do |excluded|
          case excluded
          when String
            exception.class.name == excluded || exception.class.to_s == excluded
          when Class
            exception.is_a?(excluded)
          when Regexp
            exception.class.name =~ excluded
          else
            false
          end
        end
      end

      def sampled_out?
        rate = BrainzLab.configuration.reflex_sample_rate
        return false if rate.nil? || rate >= 1.0

        rand > rate
      end

      def run_before_send(payload, exception)
        hook = BrainzLab.configuration.reflex_before_send
        return payload unless hook

        hook.call(payload, exception)
      end

      def build_payload(exception, context)
        config = BrainzLab.configuration
        ctx = Context.current

        payload = {
          timestamp: Time.now.utc.iso8601(3),
          error_class: exception.class.name,
          message: exception.message,
          backtrace: format_backtrace(exception.backtrace || []),

          # Environment
          environment: config.environment,
          commit: config.commit,
          branch: config.branch,
          server_name: config.host,

          # Request context
          request_id: ctx.request_id
        }

        # Add request info if available
        add_request_info(payload, ctx)

        # Add user info
        add_user_info(payload, ctx, context)

        # Add context, tags, extra
        add_context_data(payload, ctx, context)

        # Add breadcrumbs
        payload[:breadcrumbs] = ctx.breadcrumbs.to_a

        # Add fingerprint for error grouping
        payload[:fingerprint] = compute_fingerprint(exception, context, ctx)

        payload
      end

      def build_message_payload(message, level, context)
        config = BrainzLab.configuration
        ctx = Context.current

        payload = {
          timestamp: Time.now.utc.iso8601(3),
          error_class: "Message",
          message: message.to_s,
          level: level.to_s,

          # Environment
          environment: config.environment,
          commit: config.commit,
          branch: config.branch,
          server_name: config.host,

          # Request context
          request_id: ctx.request_id
        }

        # Add request info if available
        add_request_info(payload, ctx)

        # Add user info
        add_user_info(payload, ctx, context)

        # Add context, tags, extra
        add_context_data(payload, ctx, context)

        # Add breadcrumbs
        payload[:breadcrumbs] = ctx.breadcrumbs.to_a

        payload
      end

      def add_request_info(payload, ctx)
        return unless ctx.request_path

        payload[:request] = {
          method: ctx.request_method,
          path: ctx.request_path,
          url: ctx.request_url,
          params: filter_params(ctx.request_params),
          headers: ctx.request_headers,
          controller: ctx.controller,
          action: ctx.action
        }.compact
      end

      def add_user_info(payload, ctx, context)
        user = context[:user] || ctx.user
        return if user.nil? || user.empty?

        payload[:user] = {
          id: user[:id]&.to_s,
          email: user[:email],
          name: user[:name]
        }.compact

        # Store additional user data
        extra_user = user.except(:id, :email, :name)
        payload[:user_data] = extra_user unless extra_user.empty?
      end

      def add_context_data(payload, ctx, context)
        # Tags from context + provided tags
        tags = ctx.tags.merge(context[:tags] || {})
        payload[:tags] = tags unless tags.empty?

        # Extra data from context + provided extra
        extra = ctx.data_hash.merge(context[:extra] || {})
        extra = extra.except(:user, :tags) # Remove user and tags as they're separate
        payload[:extra] = extra unless extra.empty?

        # General context
        payload[:context] = context.except(:user, :tags, :extra) unless context.except(:user, :tags, :extra).empty?
      end

      def format_backtrace(backtrace)
        backtrace.first(30).map do |line|
          if line.is_a?(String)
            parse_backtrace_line(line)
          else
            line
          end
        end
      end

      def parse_backtrace_line(line)
        # Parse various Ruby backtrace formats:
        # - "path/to/file.rb:42:in `method_name'"  (backtick + single quote)
        # - "path/to/file.rb:42:in 'method_name'"  (single quotes)
        # - "path/to/file.rb:42"                   (no method)
        if line =~ /\A(.+):(\d+):in [`'](.+)'?\z/
          {
            file: $1,
            line: $2.to_i,
            function: $3,
            in_app: in_app_frame?($1)
          }
        elsif line =~ /\A(.+):(\d+)\z/
          {
            file: $1,
            line: $2.to_i,
            function: nil,
            in_app: in_app_frame?($1)
          }
        else
          # Still store file for display even if format is unexpected
          { file: line, line: nil, function: nil, in_app: false }
        end
      end

      def in_app_frame?(path)
        return false if path.nil?
        return false if path.include?("vendor/")
        return false if path.include?("/gems/")
        return false if path.include?("/ruby/")

        # Match both relative and absolute paths containing app/ or lib/
        path.start_with?("app/", "lib/", "./app/", "./lib/") ||
          path.include?("/app/") ||
          path.include?("/lib/")
      end

      def filter_params(params)
        return nil if params.nil?

        scrub_fields = BrainzLab.configuration.scrub_fields + FILTERED_PARAMS.map(&:to_sym)
        deep_filter(params, scrub_fields)
      end

      def deep_filter(obj, fields)
        case obj
        when Hash
          obj.each_with_object({}) do |(key, value), result|
            if should_filter?(key, fields)
              result[key] = "[FILTERED]"
            else
              result[key] = deep_filter(value, fields)
            end
          end
        when Array
          obj.map { |item| deep_filter(item, fields) }
        else
          obj
        end
      end

      def should_filter?(key, fields)
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

      # Compute fingerprint for error grouping
      # Returns an array of strings that uniquely identify the error type
      def compute_fingerprint(exception, context, ctx)
        custom_callback = BrainzLab.configuration.reflex_fingerprint

        if custom_callback
          # Call user's custom fingerprint callback
          result = custom_callback.call(exception, context, ctx)

          # Normalize the result
          case result
          when Array
            result.map(&:to_s)
          when String
            [result]
          when nil
            # nil means use default fingerprinting
            default_fingerprint(exception)
          else
            [result.to_s]
          end
        else
          default_fingerprint(exception)
        end
      rescue StandardError => e
        BrainzLab.debug_log("Custom fingerprint callback failed: #{e.message}")
        default_fingerprint(exception)
      end

      # Default fingerprint: error class + first in-app frame (or first frame)
      def default_fingerprint(exception)
        parts = [exception.class.name]

        if exception.backtrace&.any?
          # Try to find the first in-app frame
          in_app_frame = exception.backtrace.find { |line| in_app_line?(line) }
          frame = in_app_frame || exception.backtrace.first

          if frame
            # Normalize the frame (remove line numbers for consistent grouping)
            normalized = normalize_frame_for_fingerprint(frame)
            parts << normalized if normalized
          end
        end

        parts
      end

      def in_app_line?(line)
        return false if line.nil?
        return false if line.include?("vendor/")
        return false if line.include?("/gems/")

        line.start_with?("app/", "lib/", "./app/", "./lib/") ||
          line.include?("/app/") ||
          line.include?("/lib/")
      end

      def normalize_frame_for_fingerprint(frame)
        return nil unless frame.is_a?(String)

        # Extract file and method, normalize out line numbers
        # "app/models/user.rb:42:in `save'" -> "app/models/user.rb:in `save'"
        if frame =~ /\A(.+):\d+:in `(.+)'\z/
          "#{$1}:in `#{$2}'"
        elsif frame =~ /\A(.+):\d+\z/
          $1
        else
          frame
        end
      end
    end
  end
end
