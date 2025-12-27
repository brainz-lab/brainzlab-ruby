# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module TyphoeusInstrumentation
      class << self
        def install!
          return unless defined?(::Typhoeus)

          install_callbacks!

          BrainzLab.debug_log("[Instrumentation] Typhoeus instrumentation installed")
        end

        private

        def install_callbacks!
          ::Typhoeus.on_complete do |response|
            track_request(response)
          end
        end

        def track_request(response)
          request = response.request
          return unless request

          uri = URI.parse(request.base_url) rescue nil
          return unless uri

          host = uri.host
          return if skip_host?(host)

          method = (request.options[:method] || :get).to_s.upcase
          path = uri.path.empty? ? "/" : uri.path
          status = response.response_code
          duration_ms = (response.total_time * 1000).round(2)

          # Add breadcrumb
          BrainzLab::Reflex.add_breadcrumb(
            "HTTP #{method} #{host}#{path} -> #{status}",
            category: "http",
            level: response.success? ? :info : :error,
            data: {
              method: method,
              host: host,
              path: path,
              status: status,
              duration_ms: duration_ms
            }
          )

          # Track with Flux
          if BrainzLab.configuration.flux_effectively_enabled?
            tags = { host: host, method: method, status: status.to_s }
            BrainzLab::Flux.distribution("http.typhoeus.duration_ms", duration_ms, tags: tags)
            BrainzLab::Flux.increment("http.typhoeus.requests", tags: tags)

            unless response.success?
              BrainzLab::Flux.increment("http.typhoeus.errors", tags: tags)
            end

            if response.timed_out?
              BrainzLab::Flux.increment("http.typhoeus.timeouts", tags: { host: host })
            end
          end
        end

        def skip_host?(host)
          return true unless host

          ignore_hosts = BrainzLab.configuration.http_ignore_hosts || []
          ignore_hosts.any? { |h| host.include?(h) }
        end
      end

      # Hydra instrumentation for parallel requests
      module HydraInstrumentation
        def self.install!
          return unless defined?(::Typhoeus::Hydra)

          ::Typhoeus::Hydra.class_eval do
            alias_method :original_run, :run

            def run
              started_at = Time.now
              request_count = queued_requests.size

              result = original_run

              duration_ms = ((Time.now - started_at) * 1000).round(2)

              if BrainzLab.configuration.flux_effectively_enabled?
                BrainzLab::Flux.distribution("http.typhoeus.hydra.duration_ms", duration_ms)
                BrainzLab::Flux.distribution("http.typhoeus.hydra.request_count", request_count)
              end

              result
            end
          end
        end
      end
    end
  end
end
