# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module FaradayMiddleware
      @installed = false

      class << self
        def install!
          return unless defined?(::Faraday)
          return if @installed

          # Register the middleware with Faraday
          ::Faraday::Middleware.register_middleware(brainzlab: Middleware)

          @installed = true
          BrainzLab.debug_log('Faraday instrumentation installed')
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end
      end

      # Faraday middleware for HTTP request instrumentation
      # Usage:
      #   conn = Faraday.new do |f|
      #     f.use :brainzlab
      #     # or
      #     f.use BrainzLab::Instrumentation::FaradayMiddleware::Middleware
      #   end
      class Middleware < ::Faraday::Middleware
        def initialize(app, options = {})
          super(app)
          @options = options
        end

        def call(env)
          return @app.call(env) unless should_track?(env)

          # Inject distributed tracing context
          inject_trace_context(env)

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            response = @app.call(env)
            track_request(env, response.status, started_at)
            response
          rescue ::Faraday::Error => e
            error_info = e.class.name
            track_request(env, e.response&.dig(:status), started_at, error_info)
            raise
          rescue StandardError => e
            error_info = e.class.name
            track_request(env, nil, started_at, error_info)
            raise
          end
        end

        private

        def should_track?(env)
          return false unless BrainzLab.configuration.instrument_http

          ignore_hosts = BrainzLab.configuration.http_ignore_hosts || []
          host = env.url.host
          !ignore_hosts.include?(host)
        end

        def inject_trace_context(env)
          return unless BrainzLab.configuration.pulse_enabled

          headers = {}
          BrainzLab::Pulse.inject(headers, format: :all)

          headers.each do |key, value|
            env.request_headers[key] = value
          end
        rescue StandardError => e
          BrainzLab.debug_log("Failed to inject trace context: #{e.message}")
        end

        def track_request(env, status, started_at, error = nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
          method = env.method.to_s.upcase
          url = sanitize_url(env.url)
          host = env.url.host
          path = env.url.path
          level = error || (status && status >= 400) ? :error : :info

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "#{method} #{url}",
              category: 'http.faraday',
              level: level,
              data: {
                method: method,
                url: url,
                host: host,
                path: path,
                status_code: status,
                duration_ms: duration_ms,
                error: error
              }.compact
            )
          end

          # Record span for Pulse APM
          record_pulse_span(method, host, path, status, duration_ms, error)

          # Log to Recall at debug level
          if BrainzLab.configuration.recall_enabled
            BrainzLab::Recall.debug(
              "HTTP #{method} #{url} -> #{status || 'ERROR'}",
              method: method,
              url: url,
              host: host,
              status_code: status,
              duration_ms: duration_ms,
              error: error
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("Faraday instrumentation error: #{e.message}")
        end

        def record_pulse_span(method, host, path, status, duration_ms, error)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          span = {
            span_id: SecureRandom.uuid,
            name: "HTTP #{method} #{host}",
            kind: 'http',
            started_at: Time.now.utc - (duration_ms / 1000.0),
            ended_at: Time.now.utc,
            duration_ms: duration_ms,
            data: {
              method: method,
              host: host,
              path: path,
              status: status
            }.compact
          }

          if error
            span[:error] = true
            span[:error_class] = error
          end

          spans << span
        end

        def sanitize_url(url)
          # Remove sensitive query parameters
          uri = url.dup
          if uri.query
            params = URI.decode_www_form(uri.query).reject do |key, _|
              sensitive_param?(key)
            end
            uri.query = params.empty? ? nil : URI.encode_www_form(params)
          end
          uri.to_s
        rescue StandardError
          url.to_s
        end

        def sensitive_param?(key)
          key = key.to_s.downcase
          %w[token api_key apikey secret password auth key].any? { |s| key.include?(s) }
        end
      end
    end
  end
end
