# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActionController
      # Thresholds for slow request detection (in milliseconds)
      SLOW_REQUEST_THRESHOLD = 500
      VERY_SLOW_REQUEST_THRESHOLD = 2000

      class << self
        def install!
          return unless defined?(::ActionController)
          return if @installed

          install_start_processing_subscriber!
          install_process_action_subscriber!
          install_redirect_subscriber!
          install_halted_callback_subscriber!
          install_unpermitted_parameters_subscriber!
          install_send_file_subscriber!
          install_send_data_subscriber!
          install_send_stream_subscriber!

          # Fragment caching
          install_write_fragment_subscriber!
          install_read_fragment_subscriber!
          install_expire_fragment_subscriber!
          install_exist_fragment_subscriber!

          # Rails 7.1+ rate limiting
          install_rate_limit_subscriber! if rails_71_or_higher?

          @installed = true
          BrainzLab.debug_log('ActionController instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # Start Processing (request begins)
        # ============================================
        def install_start_processing_subscriber!
          ActiveSupport::Notifications.subscribe('start_processing.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_start_processing(event)
          end
        end

        def handle_start_processing(event)
          payload = event.payload

          controller = payload[:controller]
          action = payload[:action]
          method = payload[:method]
          path = payload[:path]
          format = payload[:format]
          params = payload[:params]

          # Skip health check endpoints
          return if excluded_path?(path)

          # Store start time for later use
          Thread.current[:brainzlab_request_start] = event.time

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Request started: #{method} #{controller}##{action}",
              category: 'http.start',
              level: :info,
              data: {
                controller: controller,
                action: action,
                method: method,
                path: truncate_path(path),
                format: format
              }.compact
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionController start_processing instrumentation failed: #{e.message}")
        end

        # ============================================
        # Process Action (main request instrumentation)
        # ============================================
        def install_process_action_subscriber!
          ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_process_action(event)
          end
        end

        def handle_process_action(event)
          payload = event.payload
          duration = event.duration.round(2)

          controller = payload[:controller]
          action = payload[:action]
          status = payload[:status]
          method = payload[:method]
          path = payload[:path]
          format = payload[:format]

          # Skip health check endpoints
          return if excluded_path?(path)

          # Add breadcrumb for Reflex
          record_request_breadcrumb(payload, duration, status)

          # Record trace for Pulse (if not already recording via middleware)
          record_request_trace(event, payload, duration)

          # Log slow requests to Recall
          log_slow_request(payload, duration) if duration >= SLOW_REQUEST_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActionController process_action instrumentation failed: #{e.message}")
        end

        def record_request_breadcrumb(payload, duration, status)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          controller = payload[:controller]
          action = payload[:action]
          method = payload[:method]
          path = payload[:path]

          level = case status.to_i
                  when 200..399 then :info
                  when 400..499 then :warning
                  else :error
                  end

          # Adjust for slow requests
          level = :warning if level == :info && duration >= SLOW_REQUEST_THRESHOLD
          level = :error if duration >= VERY_SLOW_REQUEST_THRESHOLD

          BrainzLab::Reflex.add_breadcrumb(
            "#{method} #{controller}##{action} -> #{status} (#{duration}ms)",
            category: 'http.request',
            level: level,
            data: {
              controller: controller,
              action: action,
              method: method,
              path: truncate_path(path),
              status: status,
              format: payload[:format],
              duration_ms: duration,
              view_ms: payload[:view_runtime]&.round(2),
              db_ms: payload[:db_runtime]&.round(2)
            }.compact
          )
        end

        def record_request_trace(event, payload, duration)
          # Only record if Pulse is enabled and no trace is already active
          # (middleware should handle this, but this is a fallback)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return if tracer.current_trace # Already being traced by middleware

          controller = payload[:controller]
          action = payload[:action]

          BrainzLab::Pulse.record_trace(
            "#{controller}##{action}",
            started_at: event.time,
            ended_at: event.end,
            kind: 'request',
            request_method: payload[:method],
            request_path: payload[:path],
            controller: controller,
            action: action,
            status: payload[:status],
            view_ms: payload[:view_runtime]&.round(2),
            db_ms: payload[:db_runtime]&.round(2),
            error: payload[:status].to_i >= 500,
            error_class: payload[:exception]&.first,
            error_message: payload[:exception]&.last
          )
        end

        def log_slow_request(payload, duration)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          level = duration >= VERY_SLOW_REQUEST_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow request: #{payload[:controller]}##{payload[:action]} (#{duration}ms)",
            controller: payload[:controller],
            action: payload[:action],
            method: payload[:method],
            path: truncate_path(payload[:path]),
            status: payload[:status],
            format: payload[:format],
            duration_ms: duration,
            view_ms: payload[:view_runtime]&.round(2),
            db_ms: payload[:db_runtime]&.round(2),
            threshold_exceeded: duration >= VERY_SLOW_REQUEST_THRESHOLD ? 'critical' : 'warning'
          )
        end

        # ============================================
        # Redirect Tracking
        # ============================================
        def install_redirect_subscriber!
          ActiveSupport::Notifications.subscribe('redirect_to.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_redirect(event)
          end
        end

        def handle_redirect(event)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          payload = event.payload
          location = payload[:location]
          status = payload[:status] || 302

          BrainzLab::Reflex.add_breadcrumb(
            "Redirect -> #{truncate_path(location)} (#{status})",
            category: 'http.redirect',
            level: :info,
            data: {
              location: truncate_path(location),
              status: status
            }
          )
        rescue StandardError => e
          BrainzLab.debug_log("ActionController redirect instrumentation failed: #{e.message}")
        end

        # ============================================
        # Halted Callbacks (before_action filters)
        # ============================================
        def install_halted_callback_subscriber!
          ActiveSupport::Notifications.subscribe('halted_callback.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_halted_callback(event)
          end
        end

        def handle_halted_callback(event)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          payload = event.payload
          filter = payload[:filter]

          BrainzLab::Reflex.add_breadcrumb(
            "Request halted by filter: #{filter}",
            category: 'http.filter',
            level: :warning,
            data: {
              filter: filter.to_s
            }
          )

          # Also log to Recall - halted callbacks can indicate auth issues
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.info(
              "Request halted by before_action filter",
              filter: filter.to_s
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionController halted_callback instrumentation failed: #{e.message}")
        end

        # ============================================
        # Unpermitted Parameters (Strong Parameters)
        # ============================================
        def install_unpermitted_parameters_subscriber!
          ActiveSupport::Notifications.subscribe('unpermitted_parameters.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_unpermitted_parameters(event)
          end
        end

        def handle_unpermitted_parameters(event)
          payload = event.payload
          keys = payload[:keys] || []
          context = payload[:context] || {}

          return if keys.empty?

          # Add breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Unpermitted parameters: #{keys.join(', ')}",
              category: 'security.params',
              level: :warning,
              data: {
                unpermitted_keys: keys,
                controller: context[:controller],
                action: context[:action]
              }.compact
            )
          end

          # Log to Recall - this is a security-relevant event
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Unpermitted parameters rejected",
              unpermitted_keys: keys,
              controller: context[:controller],
              action: context[:action]
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionController unpermitted_parameters instrumentation failed: #{e.message}")
        end

        # ============================================
        # Send File
        # ============================================
        def install_send_file_subscriber!
          ActiveSupport::Notifications.subscribe('send_file.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_send_file(event)
          end
        end

        def handle_send_file(event)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          payload = event.payload
          path = payload[:path]

          BrainzLab::Reflex.add_breadcrumb(
            "Sending file: #{File.basename(path.to_s)}",
            category: 'http.file',
            level: :info,
            data: {
              filename: File.basename(path.to_s)
            }
          )
        rescue StandardError => e
          BrainzLab.debug_log("ActionController send_file instrumentation failed: #{e.message}")
        end

        # ============================================
        # Send Data
        # ============================================
        def install_send_data_subscriber!
          ActiveSupport::Notifications.subscribe('send_data.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_send_data(event)
          end
        end

        def handle_send_data(event)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          payload = event.payload
          filename = payload[:filename]

          BrainzLab::Reflex.add_breadcrumb(
            "Sending data#{filename ? ": #{filename}" : ''}",
            category: 'http.data',
            level: :info,
            data: {
              filename: filename
            }.compact
          )
        rescue StandardError => e
          BrainzLab.debug_log("ActionController send_data instrumentation failed: #{e.message}")
        end

        # ============================================
        # Send Stream (streaming responses)
        # ============================================
        def install_send_stream_subscriber!
          ActiveSupport::Notifications.subscribe('send_stream.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_send_stream(event)
          end
        end

        def handle_send_stream(event)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          payload = event.payload
          filename = payload[:filename]
          type = payload[:type]

          BrainzLab::Reflex.add_breadcrumb(
            "Streaming#{filename ? ": #{filename}" : ''}",
            category: 'http.stream',
            level: :info,
            data: {
              filename: filename,
              type: type
            }.compact
          )
        rescue StandardError => e
          BrainzLab.debug_log("ActionController send_stream instrumentation failed: #{e.message}")
        end

        # ============================================
        # Fragment Caching: Write
        # ============================================
        def install_write_fragment_subscriber!
          ActiveSupport::Notifications.subscribe('write_fragment.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_write_fragment(event)
          end
        end

        def handle_write_fragment(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Fragment cache write: #{truncate_cache_key(key)} (#{duration}ms)",
              category: 'cache.fragment.write',
              level: :info,
              data: {
                key: truncate_cache_key(key),
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_fragment_cache_span(event, 'write', key, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActionController write_fragment instrumentation failed: #{e.message}")
        end

        # ============================================
        # Fragment Caching: Read
        # ============================================
        def install_read_fragment_subscriber!
          ActiveSupport::Notifications.subscribe('read_fragment.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_read_fragment(event)
          end
        end

        def handle_read_fragment(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          hit = payload[:hit]

          if BrainzLab.configuration.reflex_effectively_enabled?
            status = hit ? 'hit' : 'miss'
            BrainzLab::Reflex.add_breadcrumb(
              "Fragment cache #{status}: #{truncate_cache_key(key)} (#{duration}ms)",
              category: 'cache.fragment.read',
              level: :info,
              data: {
                key: truncate_cache_key(key),
                hit: hit,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_fragment_cache_span(event, 'read', key, duration, hit: hit)
        rescue StandardError => e
          BrainzLab.debug_log("ActionController read_fragment instrumentation failed: #{e.message}")
        end

        # ============================================
        # Fragment Caching: Expire
        # ============================================
        def install_expire_fragment_subscriber!
          ActiveSupport::Notifications.subscribe('expire_fragment.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_expire_fragment(event)
          end
        end

        def handle_expire_fragment(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Fragment cache expire: #{truncate_cache_key(key)} (#{duration}ms)",
              category: 'cache.fragment.expire',
              level: :info,
              data: {
                key: truncate_cache_key(key),
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_fragment_cache_span(event, 'expire', key, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActionController expire_fragment instrumentation failed: #{e.message}")
        end

        # ============================================
        # Fragment Caching: Exist?
        # ============================================
        def install_exist_fragment_subscriber!
          ActiveSupport::Notifications.subscribe('exist_fragment?.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_exist_fragment(event)
          end
        end

        def handle_exist_fragment(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          exist = payload[:exist]

          # Only track slow checks or misses
          return if duration < 1 && exist

          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Fragment cache exist?: #{truncate_cache_key(key)} -> #{exist} (#{duration}ms)",
              category: 'cache.fragment.exist',
              level: :info,
              data: {
                key: truncate_cache_key(key),
                exist: exist,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_fragment_cache_span(event, 'exist', key, duration, exist: exist)
        rescue StandardError => e
          BrainzLab.debug_log("ActionController exist_fragment instrumentation failed: #{e.message}")
        end

        def record_fragment_cache_span(event, operation, key, duration, **extra)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "cache.fragment.#{operation}",
            kind: 'cache',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'cache.operation' => operation,
              'cache.key' => truncate_cache_key(key)
            }.merge(extra.transform_keys { |k| "cache.#{k}" }).compact
          }

          tracer.current_spans << span_data
        end

        def truncate_cache_key(key, max_length = 100)
          return 'unknown' unless key

          key_str = key.to_s
          if key_str.length > max_length
            "#{key_str[0, max_length - 3]}..."
          else
            key_str
          end
        end

        # ============================================
        # Rate Limiting (Rails 7.1+)
        # ============================================
        def install_rate_limit_subscriber!
          ActiveSupport::Notifications.subscribe('rate_limit.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_rate_limit(event)
          end
        end

        def handle_rate_limit(event)
          payload = event.payload

          # Add breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Rate limit triggered",
              category: 'security.rate_limit',
              level: :warning,
              data: {
                request: payload[:request]&.path
              }.compact
            )
          end

          # Log to Recall - rate limiting is security-relevant
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Rate limit triggered",
              path: payload[:request]&.path,
              ip: payload[:request]&.remote_ip
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionController rate_limit instrumentation failed: #{e.message}")
        end

        # ============================================
        # Helper Methods
        # ============================================
        def excluded_path?(path)
          excluded_paths = BrainzLab.configuration.pulse_excluded_paths || []
          excluded_paths.any? { |excluded| path.to_s.start_with?(excluded) }
        end

        def truncate_path(path, max_length = 200)
          return nil unless path

          path_str = path.to_s
          if path_str.length > max_length
            "#{path_str[0, max_length - 3]}..."
          else
            path_str
          end
        end

        def rails_71_or_higher?
          return false unless defined?(::Rails::VERSION)

          ::Rails::VERSION::MAJOR > 7 ||
            (::Rails::VERSION::MAJOR == 7 && ::Rails::VERSION::MINOR >= 1)
        end
      end
    end
  end
end
