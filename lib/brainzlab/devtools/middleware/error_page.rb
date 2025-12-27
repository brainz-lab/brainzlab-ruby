# frozen_string_literal: true

module BrainzLab
  module DevTools
    module Middleware
      class ErrorPage
        def initialize(app)
          @app = app
          @renderer = Renderers::ErrorPageRenderer.new
        end

        def call(env)
          $stderr.puts "[BrainzLab::ErrorPage] call() for #{env['PATH_INFO']}"

          unless should_handle?(env)
            $stderr.puts "[BrainzLab::ErrorPage] should_handle? returned false, passing through"
            return @app.call(env)
          end

          $stderr.puts "[BrainzLab::ErrorPage] should_handle? returned true, wrapping request"

          begin
            status, headers, body = @app.call(env)
            $stderr.puts "[BrainzLab::ErrorPage] Request completed normally with status #{status}"
            [status, headers, body]
          rescue Exception => exception
            $stderr.puts "[BrainzLab::ErrorPage] Caught exception: #{exception.class}: #{exception.message}"

            # Don't intercept if request wants JSON
            if json_request?(env)
              $stderr.puts "[BrainzLab::ErrorPage] JSON request, re-raising"
              return raise_exception(exception)
            end

            # Still capture to Reflex if available
            capture_to_reflex(exception)

            # Collect debug data
            data = collect_debug_data(env, exception)

            # Render branded error page
            $stderr.puts "[BrainzLab::ErrorPage] Rendering branded error page"
            render_error_page(exception, data)
          end
        end

        private

        def should_handle?(env)
          return false unless DevTools.error_page_enabled?
          return false unless DevTools.allowed_environment?
          return false unless DevTools.allowed_ip?(extract_ip(env))

          true
        end

        def extract_ip(env)
          forwarded = env["HTTP_X_FORWARDED_FOR"]
          return forwarded.split(",").first.strip if forwarded

          env["REMOTE_ADDR"]
        end

        def json_request?(env)
          accept = env["HTTP_ACCEPT"] || ""
          content_type = env["CONTENT_TYPE"] || ""

          accept.include?("application/json") ||
            content_type.include?("application/json") ||
            env["HTTP_X_REQUESTED_WITH"] == "XMLHttpRequest"
        end

        def capture_to_reflex(exception)
          return unless defined?(BrainzLab::Reflex)

          BrainzLab::Reflex.capture(exception)
        rescue StandardError
          # Ignore errors in error capturing
        end

        def raise_exception(exception)
          raise exception
        end

        def collect_debug_data(env, exception)
          context = defined?(BrainzLab::Context) ? BrainzLab::Context.current : nil
          collector_data = Data::Collector.get_request_data

          {
            exception: exception,
            backtrace: format_backtrace(exception),
            request: build_request_info(env, context),
            context: build_context_info(context),
            sql_queries: collector_data.dig(:database, :queries) || [],
            environment: collect_environment_info,
            source_extract: extract_source_lines(exception)
          }
        end

        def build_request_info(env, context)
          request = defined?(ActionDispatch::Request) ? ActionDispatch::Request.new(env) : nil

          {
            method: request&.request_method || env["REQUEST_METHOD"],
            path: request&.path || env["PATH_INFO"],
            url: request&.url || env["REQUEST_URI"],
            params: scrub_params(context&.request_params || extract_params(env)),
            headers: extract_headers(env),
            session: {}
          }
        end

        def build_context_info(context)
          {
            controller: context&.controller,
            action: context&.action,
            request_id: context&.request_id,
            user: context&.user
          }
        end

        def extract_params(env)
          return {} unless defined?(Rack::Request)

          Rack::Request.new(env).params
        rescue StandardError
          {}
        end

        def extract_headers(env)
          headers = {}
          env.each do |key, value|
            if key.start_with?("HTTP_")
              header_name = key.sub("HTTP_", "").split("_").map(&:capitalize).join("-")
              headers[header_name] = value
            end
          end
          headers
        end

        def scrub_params(params)
          return {} unless params.is_a?(Hash)

          scrub_fields = BrainzLab.configuration.scrub_fields.map(&:to_s)

          params.transform_values.with_index do |(key, value), _|
            if scrub_fields.include?(key.to_s.downcase)
              "[FILTERED]"
            elsif value.is_a?(Hash)
              scrub_params(value)
            else
              value
            end
          end
        rescue StandardError
          params
        end

        def format_backtrace(exception)
          (exception.backtrace || []).first(50).map do |line|
            parsed = parse_backtrace_line(line)
            parsed[:in_app] = in_app_frame?(parsed[:file])
            parsed
          end
        end

        def parse_backtrace_line(line)
          match = line.match(/\A(.+):(\d+)(?::in `(.+)')?/)
          return { file: line, line: 0, function: nil, raw: line } unless match

          {
            file: match[1],
            line: match[2].to_i,
            function: match[3],
            raw: line
          }
        end

        def in_app_frame?(file)
          return false unless file

          file.include?("/app/") && !file.include?("/vendor/") && !file.include?("/gems/")
        end

        def extract_source_lines(exception)
          return nil unless exception.backtrace&.first

          match = exception.backtrace.first.match(/\A(.+):(\d+)/)
          return nil unless match

          file = match[1]
          line_number = match[2].to_i
          return nil unless File.exist?(file)

          lines = File.readlines(file)
          start_line = [line_number - 6, 0].max
          end_line = [line_number + 4, lines.length - 1].min

          {
            file: file,
            line_number: line_number,
            lines: lines[start_line..end_line].map.with_index do |content, idx|
              {
                number: start_line + idx + 1,
                content: content.chomp,
                highlight: (start_line + idx + 1) == line_number
              }
            end
          }
        rescue StandardError
          nil
        end

        def collect_environment_info
          {
            rails_version: defined?(Rails::VERSION::STRING) ? Rails::VERSION::STRING : "N/A",
            ruby_version: RUBY_VERSION,
            env: BrainzLab.configuration.environment,
            server: ENV["SERVER_SOFTWARE"] || "Unknown",
            pid: Process.pid
          }
        end

        def render_error_page(exception, data)
          html = @renderer.render(exception, data)

          [
            500,
            {
              "Content-Type" => "text/html; charset=utf-8",
              "Content-Length" => html.bytesize.to_s,
              "X-Content-Type-Options" => "nosniff"
            },
            [html]
          ]
        end
      end
    end
  end
end
