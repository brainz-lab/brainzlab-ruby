# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module NetHttp
      @installed = false

      class << self
        def install!
          return if @installed

          ::Net::HTTP.prepend(Patch)
          @installed = true
        end

        def installed?
          @installed
        end

        # For testing purposes
        def reset!
          @installed = false
        end
      end

      module Patch
        def request(req, body = nil, &block)
          return super unless should_track?

          url = build_url(req)
          method = req.method
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            response = super
            track_request(method, url, response.code.to_i, started_at)
            response
          rescue => e
            track_request(method, url, nil, started_at, e.class.name)
            raise
          end
        end

        private

        def should_track?
          return false unless BrainzLab.configuration.instrument_http

          ignore_hosts = BrainzLab.configuration.http_ignore_hosts || []
          !ignore_hosts.include?(address)
        end

        def build_url(req)
          scheme = use_ssl? ? "https" : "http"
          port_str = if (use_ssl? && port == 443) || (!use_ssl? && port == 80)
                       ""
                     else
                       ":#{port}"
                     end
          "#{scheme}://#{address}#{port_str}#{req.path}"
        end

        def track_request(method, url, status, started_at, error = nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
          level = error || (status && status >= 400) ? :error : :info

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "#{method} #{url}",
              category: "http",
              level: level,
              data: { method: method, url: url, status_code: status, duration_ms: duration_ms, error: error }.compact
            )
          end

          # Log to Recall at debug level (avoid noise)
          if BrainzLab.configuration.recall_enabled
            BrainzLab::Recall.debug(
              "HTTP #{method} #{url} -> #{status || 'ERROR'}",
              method: method, url: url, status_code: status, duration_ms: duration_ms, error: error
            )
          end
        rescue => e
          # Don't let instrumentation errors crash the app
          BrainzLab.configuration.logger&.error("[BrainzLab] HTTP instrumentation error: #{e.message}")
        end
      end
    end
  end
end
