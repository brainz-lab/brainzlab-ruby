# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module HTTPartyInstrumentation
      @installed = false

      class << self
        def install!
          return unless defined?(::HTTParty)
          return if @installed

          ::HTTParty.singleton_class.prepend(Patch)

          @installed = true
          BrainzLab.debug_log('HTTParty instrumentation installed')
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end
      end

      module Patch
        def perform_request(http_method, path, options = {}, &)
          return super unless should_track?(path, options)

          # Inject distributed tracing headers
          options = inject_trace_context(options)

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            response = super
            track_request(http_method, path, options, response.code, started_at)
            response
          rescue StandardError => e
            error_info = e.class.name
            track_request(http_method, path, options, nil, started_at, error_info)
            raise
          end
        end

        private

        def should_track?(path, options)
          return false unless BrainzLab.configuration.instrument_http

          uri = parse_uri(path, options)
          return true unless uri

          ignore_hosts = BrainzLab.configuration.http_ignore_hosts || []
          !ignore_hosts.include?(uri.host)
        end

        def inject_trace_context(options)
          return options unless BrainzLab.configuration.pulse_enabled

          options = options.dup
          options[:headers] ||= {}

          trace_headers = {}
          BrainzLab::Pulse.inject(trace_headers, format: :all)

          options[:headers] = options[:headers].merge(trace_headers)
          options
        rescue StandardError => e
          BrainzLab.debug_log("Failed to inject trace context: #{e.message}")
          options
        end

        def track_request(http_method, path, options, status, started_at, error = nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
          method = extract_method_name(http_method)
          uri = parse_uri(path, options)
          url = uri ? sanitize_url(uri) : path.to_s
          host = uri&.host || 'unknown'
          request_path = uri&.path || path.to_s
          level = error || (status && status >= 400) ? :error : :info

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "#{method} #{url}",
              category: 'http.httparty',
              level: level,
              data: {
                method: method,
                url: url,
                host: host,
                path: request_path,
                status_code: status,
                duration_ms: duration_ms,
                error: error
              }.compact
            )
          end

          # Record span for Pulse APM
          record_pulse_span(method, host, request_path, status, duration_ms, error)

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
          BrainzLab.debug_log("HTTParty instrumentation error: #{e.message}")
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

        def extract_method_name(http_method)
          case http_method.name
          when /Get$/ then 'GET'
          when /Post$/ then 'POST'
          when /Put$/ then 'PUT'
          when /Patch$/ then 'PATCH'
          when /Delete$/ then 'DELETE'
          when /Head$/ then 'HEAD'
          when /Options$/ then 'OPTIONS'
          else http_method.name.split('::').last.upcase
          end
        end

        def parse_uri(path, options)
          base_uri = options[:base_uri]
          if base_uri
            URI.join(base_uri.to_s, path.to_s)
          else
            URI.parse(path.to_s)
          end
        rescue URI::InvalidURIError
          nil
        end

        def sanitize_url(uri)
          result = uri.dup
          if result.query
            params = URI.decode_www_form(result.query).reject do |key, _|
              sensitive_param?(key)
            end
            result.query = params.empty? ? nil : URI.encode_www_form(params)
          end
          result.to_s
        rescue StandardError
          uri.to_s
        end

        def sensitive_param?(key)
          key = key.to_s.downcase
          %w[token api_key apikey secret password auth key].any? { |s| key.include?(s) }
        end
      end
    end
  end
end
