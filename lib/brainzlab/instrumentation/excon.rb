# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module ExconInstrumentation
      class << self
        def install!
          return unless defined?(::Excon)

          install_middleware!

          BrainzLab.debug_log("[Instrumentation] Excon instrumentation installed")
        end

        private

        def install_middleware!
          # Add our instrumentor to Excon defaults
          ::Excon.defaults[:instrumentor] = BrainzLabInstrumentor

          # Also set up middleware
          if ::Excon.defaults[:middlewares]
            ::Excon.defaults[:middlewares] = [Middleware] + ::Excon.defaults[:middlewares]
          end
        end
      end

      # Excon Instrumentor for ActiveSupport-style notifications
      module BrainzLabInstrumentor
        def self.instrument(name, params = {}, &block)
          started_at = Time.now

          begin
            result = yield if block_given?
            track_request(name, params, started_at, nil)
            result
          rescue StandardError => e
            track_request(name, params, started_at, e)
            raise
          end
        end

        def self.track_request(name, params, started_at, error)
          return if skip_tracking?(params)

          duration_ms = ((Time.now - started_at) * 1000).round(2)
          host = params[:host] || "unknown"
          method = (params[:method] || "GET").to_s.upcase
          path = params[:path] || "/"
          status = params[:status]

          # Add breadcrumb
          BrainzLab::Reflex.add_breadcrumb(
            "HTTP #{method} #{host}#{path}",
            category: "http",
            level: error ? :error : :info,
            data: {
              method: method,
              host: host,
              path: path,
              status: status,
              duration_ms: duration_ms
            }
          )

          # Track with Pulse
          if BrainzLab.configuration.pulse_effectively_enabled?
            BrainzLab::Pulse.span("http.excon", kind: "http") do
              # Already completed, just recording
            end
          end

          # Track with Flux
          if BrainzLab.configuration.flux_effectively_enabled?
            tags = { host: host, method: method, status: status.to_s }
            BrainzLab::Flux.distribution("http.excon.duration_ms", duration_ms, tags: tags)
            BrainzLab::Flux.increment("http.excon.requests", tags: tags)

            if error || (status && status >= 400)
              BrainzLab::Flux.increment("http.excon.errors", tags: tags)
            end
          end
        end

        def self.skip_tracking?(params)
          host = params[:host]
          return true unless host

          ignore_hosts = BrainzLab.configuration.http_ignore_hosts || []
          ignore_hosts.any? { |h| host.include?(h) }
        end
      end

      # Excon Middleware
      class Middleware
        def initialize(stack)
          @stack = stack
        end

        def request_call(datum)
          datum[:brainzlab_started_at] = Time.now
          @stack.request_call(datum)
        end

        def response_call(datum)
          track_response(datum)
          @stack.response_call(datum)
        end

        def error_call(datum)
          track_response(datum, error: true)
          @stack.error_call(datum)
        end

        private

        def track_response(datum, error: false)
          started_at = datum[:brainzlab_started_at]
          return unless started_at

          host = datum[:host]
          return if skip_host?(host)

          duration_ms = ((Time.now - started_at) * 1000).round(2)
          method = (datum[:method] || "GET").to_s.upcase
          path = datum[:path] || "/"
          status = datum[:response]&.dig(:status)

          BrainzLab::Reflex.add_breadcrumb(
            "HTTP #{method} #{host}#{path} -> #{status || 'error'}",
            category: "http",
            level: error ? :error : :info,
            data: { method: method, host: host, status: status, duration_ms: duration_ms }
          )

          if BrainzLab.configuration.flux_effectively_enabled?
            tags = { host: host, method: method }
            tags[:status] = status.to_s if status
            BrainzLab::Flux.distribution("http.excon.duration_ms", duration_ms, tags: tags)
          end
        end

        def skip_host?(host)
          return true unless host

          ignore_hosts = BrainzLab.configuration.http_ignore_hosts || []
          ignore_hosts.any? { |h| host.include?(h) }
        end
      end
    end
  end
end
