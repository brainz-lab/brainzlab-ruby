# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActionDispatch
      # Thresholds for slow operations (in milliseconds)
      SLOW_MIDDLEWARE_THRESHOLD = 50
      VERY_SLOW_MIDDLEWARE_THRESHOLD = 200

      class << self
        def install!
          return unless defined?(::ActionDispatch)
          return if @installed

          install_process_middleware_subscriber!
          install_redirect_subscriber!
          install_request_subscriber!

          @installed = true
          BrainzLab.debug_log('ActionDispatch instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # process_middleware.action_dispatch
        # Fired when a middleware in the stack runs
        # ============================================
        def install_process_middleware_subscriber!
          ActiveSupport::Notifications.subscribe('process_middleware.action_dispatch') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_process_middleware(event)
          end
        end

        def handle_process_middleware(event)
          payload = event.payload
          duration = event.duration.round(2)

          middleware = payload[:middleware]

          # Skip fast middleware to reduce noise
          return if duration < 1

          # Determine level based on duration
          level = case duration
                  when 0...SLOW_MIDDLEWARE_THRESHOLD then :info
                  when SLOW_MIDDLEWARE_THRESHOLD...VERY_SLOW_MIDDLEWARE_THRESHOLD then :warning
                  else :error
                  end

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Middleware: #{middleware} (#{duration}ms)",
              category: 'dispatch.middleware',
              level: level,
              data: {
                middleware: middleware,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_middleware_span(event, middleware, duration)

          # Log slow middleware
          if duration >= SLOW_MIDDLEWARE_THRESHOLD && BrainzLab.configuration.recall_effectively_enabled?
            log_level = duration >= VERY_SLOW_MIDDLEWARE_THRESHOLD ? :error : :warn
            BrainzLab::Recall.send(
              log_level,
              "Slow middleware: #{middleware} (#{duration}ms)",
              middleware: middleware,
              duration_ms: duration
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActionDispatch process_middleware instrumentation failed: #{e.message}")
        end

        # ============================================
        # redirect.action_dispatch
        # Fired when a redirect response is sent
        # ============================================
        def install_redirect_subscriber!
          ActiveSupport::Notifications.subscribe('redirect.action_dispatch') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_redirect(event)
          end
        end

        def handle_redirect(event)
          payload = event.payload
          duration = event.duration.round(2)

          status = payload[:status]
          location = payload[:location]
          request = payload[:request]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Redirect #{status}: #{truncate_url(location)}",
              category: 'dispatch.redirect',
              level: :info,
              data: {
                status: status,
                location: truncate_url(location),
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_redirect_span(event, status, location, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActionDispatch redirect instrumentation failed: #{e.message}")
        end

        # ============================================
        # request.action_dispatch
        # Fired for the full request lifecycle
        # ============================================
        def install_request_subscriber!
          ActiveSupport::Notifications.subscribe('request.action_dispatch') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_request(event)
          end
        end

        def handle_request(event)
          payload = event.payload
          duration = event.duration.round(2)

          request = payload[:request]
          response = payload[:response]

          method = request&.method
          path = request&.path
          status = response&.status

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            level = status && status >= 400 ? :warning : :info
            level = :error if status && status >= 500

            BrainzLab::Reflex.add_breadcrumb(
              "Request: #{method} #{path} -> #{status} (#{duration}ms)",
              category: 'dispatch.request',
              level: level,
              data: {
                method: method,
                path: path,
                status: status,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_request_span(event, method, path, status, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActionDispatch request instrumentation failed: #{e.message}")
        end

        # ============================================
        # Span Recording Helpers
        # ============================================
        def record_middleware_span(event, middleware, duration)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "middleware.#{middleware.to_s.demodulize.underscore}",
            kind: 'middleware',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'middleware.class' => middleware
            }.compact
          }

          tracer.current_spans << span_data
        end

        def record_redirect_span(event, status, location, duration)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: 'dispatch.redirect',
            kind: 'http',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'http.status' => status,
              'http.redirect_location' => truncate_url(location)
            }.compact
          }

          tracer.current_spans << span_data
        end

        def record_request_span(event, method, path, status, duration)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: 'dispatch.request',
            kind: 'http',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: status && status >= 500,
            data: {
              'http.method' => method,
              'http.path' => path,
              'http.status' => status
            }.compact
          }

          tracer.current_spans << span_data
        end

        # ============================================
        # Helper Methods
        # ============================================
        def truncate_url(url, max_length = 200)
          return 'unknown' unless url

          url_str = url.to_s
          if url_str.length > max_length
            "#{url_str[0, max_length - 3]}..."
          else
            url_str
          end
        end
      end
    end
  end
end
