# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module GrapeInstrumentation
      @installed = false

      class << self
        def install!
          return unless defined?(::Grape::API)
          return if @installed

          # Subscribe to Grape's ActiveSupport notifications
          install_notifications!

          @installed = true
          BrainzLab.debug_log('Grape instrumentation installed')
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end

        private

        def install_notifications!
          # Grape emits these notifications
          ActiveSupport::Notifications.subscribe('endpoint_run.grape') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_endpoint(event)
          end

          ActiveSupport::Notifications.subscribe('endpoint_render.grape') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_render(event)
          end

          ActiveSupport::Notifications.subscribe('endpoint_run_filters.grape') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_filters(event)
          end

          # Format validation
          ActiveSupport::Notifications.subscribe('format_response.grape') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_format(event)
          end
        rescue StandardError => e
          BrainzLab.debug_log("Grape notifications setup failed: #{e.message}")
        end

        def record_endpoint(event)
          payload = event.payload
          endpoint = payload[:endpoint]
          env = payload[:env] || {}

          method = env['REQUEST_METHOD'] || 'GET'
          path = endpoint&.options&.dig(:path)&.first || env['PATH_INFO'] || '/'
          route_pattern = extract_route_pattern(endpoint)
          duration_ms = event.duration.round(2)

          status = env['api.endpoint']&.status || 200
          level = status >= 400 ? :error : :info

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Grape #{method} #{route_pattern}",
              category: 'grape.endpoint',
              level: level,
              data: {
                method: method,
                path: path,
                route: route_pattern,
                status: status,
                duration_ms: duration_ms
              }.compact
            )
          end

          # Record span for Pulse
          record_span(
            name: "Grape #{method} #{route_pattern}",
            kind: 'grape',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration_ms,
            data: {
              method: method,
              path: path,
              route: route_pattern,
              status: status
            }.compact,
            error: status >= 500
          )

          # Log to Recall
          if BrainzLab.configuration.recall_enabled
            BrainzLab::Recall.info(
              "Grape #{method} #{path} -> #{status} (#{duration_ms}ms)",
              method: method,
              path: path,
              route: route_pattern,
              status: status,
              duration_ms: duration_ms
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("Grape endpoint recording failed: #{e.message}")
        end

        def record_render(event)
          duration_ms = event.duration.round(2)

          record_span(
            name: 'Grape render',
            kind: 'grape.render',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration_ms,
            data: { phase: 'render' }
          )
        rescue StandardError => e
          BrainzLab.debug_log("Grape render recording failed: #{e.message}")
        end

        def record_filters(event)
          payload = event.payload
          duration_ms = event.duration.round(2)
          filter_type = payload[:type] || 'filter'

          record_span(
            name: "Grape #{filter_type} filters",
            kind: 'grape.filter',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration_ms,
            data: { type: filter_type }
          )
        rescue StandardError => e
          BrainzLab.debug_log("Grape filters recording failed: #{e.message}")
        end

        def record_format(event)
          duration_ms = event.duration.round(2)

          record_span(
            name: 'Grape format response',
            kind: 'grape.format',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration_ms,
            data: { phase: 'format' }
          )
        rescue StandardError => e
          BrainzLab.debug_log("Grape format recording failed: #{e.message}")
        end

        def record_span(name:, kind:, started_at:, ended_at:, duration_ms:, data:, error: false)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          spans << {
            span_id: SecureRandom.uuid,
            name: name,
            kind: kind,
            started_at: started_at,
            ended_at: ended_at,
            duration_ms: duration_ms,
            data: data,
            error: error
          }
        end

        def extract_route_pattern(endpoint)
          return '/' unless endpoint

          route = endpoint.route
          return '/' unless route

          route.pattern&.path || route.path || '/'
        rescue StandardError
          '/'
        end
      end

      # Middleware for Grape (alternative installation)
      # Usage: use BrainzLab::Instrumentation::GrapeInstrumentation::Middleware
      class Middleware
        def initialize(app)
          @app = app
        end

        def call(env)
          return @app.call(env) unless should_trace?

          started_at = Time.now.utc
          request = Rack::Request.new(env)

          # Initialize Pulse tracing
          Thread.current[:brainzlab_pulse_spans] = []
          Thread.current[:brainzlab_pulse_breakdown] = nil

          # Extract parent trace context
          parent_context = BrainzLab::Pulse.extract!(env)

          begin
            status, headers, response = @app.call(env)

            record_trace(request, env, started_at, status, parent_context)

            [status, headers, response]
          rescue StandardError => e
            record_trace(request, env, started_at, 500, parent_context, e)
            raise
          ensure
            cleanup_context
          end
        end

        private

        def should_trace?
          BrainzLab.configuration.pulse_enabled
        end

        def cleanup_context
          Thread.current[:brainzlab_pulse_spans] = nil
          Thread.current[:brainzlab_pulse_breakdown] = nil
          BrainzLab::Context.clear!
          BrainzLab::Pulse::Propagation.clear!
        end

        def record_trace(request, env, started_at, status, parent_context, error = nil)
          ended_at = Time.now.utc
          duration_ms = ((ended_at - started_at) * 1000).round(2)

          method = request.request_method
          path = request.path

          # Get route pattern from Grape if available
          route_pattern = env['grape.routing_args']&.dig(:route_info)&.pattern&.path || path

          spans = Thread.current[:brainzlab_pulse_spans] || []

          payload = {
            trace_id: SecureRandom.uuid,
            name: "#{method} #{route_pattern}",
            kind: 'request',
            started_at: started_at.utc.iso8601(3),
            ended_at: ended_at.utc.iso8601(3),
            duration_ms: duration_ms,
            request_method: method,
            request_path: path,
            status: status,
            error: error.present? || status >= 500,
            error_class: error&.class&.name,
            error_message: error&.message&.slice(0, 1000),
            spans: spans.map { |s| format_span(s) },
            environment: BrainzLab.configuration.environment,
            commit: BrainzLab.configuration.commit,
            host: BrainzLab.configuration.host
          }

          if parent_context&.valid?
            payload[:parent_trace_id] = parent_context.trace_id
            payload[:parent_span_id] = parent_context.span_id
          end

          BrainzLab::Pulse.client.send_trace(payload.compact)
        rescue StandardError => e
          BrainzLab.debug_log("Grape trace recording failed: #{e.message}")
        end

        def format_span(span)
          {
            span_id: span[:span_id],
            name: span[:name],
            kind: span[:kind],
            started_at: span[:started_at]&.utc&.iso8601(3),
            ended_at: span[:ended_at]&.utc&.iso8601(3),
            duration_ms: span[:duration_ms],
            data: span[:data]
          }.compact
        end
      end
    end
  end
end
