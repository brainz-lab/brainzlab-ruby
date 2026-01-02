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
          return @app.call(env) unless should_handle?(env)

          begin
            status, headers, body = @app.call(env)

            # Check if this is an error response that we should intercept
            if status >= 400 && html_response?(headers) && !json_request?(env)
              # Check if this looks like Rails' default error page
              body_content = collect_body(body)
              if body_content.include?('Action Controller: Exception caught') || body_content.include?('background: #C00')
                # Extract exception info from the page
                exception_info = extract_exception_from_html(body_content)
                if exception_info
                  data = collect_debug_data_from_info(env, exception_info)
                  return render_error_page_from_info(exception_info, data)
                end
              end
            end

            [status, headers, body]
          rescue Exception => e
            # Don't intercept if request wants JSON
            return raise_exception(e) if json_request?(env)

            # Still capture to Reflex if available
            capture_to_reflex(e)

            # Collect debug data and render branded error page
            data = collect_debug_data(env, e)
            render_error_page(e, data)
          end
        end

        def html_response?(headers)
          # Handle both uppercase and lowercase header names
          content_type = headers['Content-Type'] || headers['content-type'] || ''
          content_type.to_s.downcase.include?('text/html')
        end

        def extract_exception_from_html(body)
          # Try to extract exception class and message from Rails error page
          if (match = body.match(%r{<h1>([^<]+)</h1>}))
            error_title = match[1]
            # Extract the exception message from the page
            if (msg_match = body.match(%r{<pre[^>]*>([^<]+)</pre>}))
              error_message = msg_match[1]
            end

            # Try to extract backtrace from Rails 8 format
            # Format: <a class="trace-frames ...">path/to/file.rb:123:in 'method'</a>
            backtrace = []
            body.scan(%r{<a[^>]*class="trace-frames[^"]*"[^>]*>\s*([^<]+)\s*</a>}m) do |trace_match|
              line = trace_match[0].strip
              # Decode HTML entities
              line = line.gsub('&#39;', "'").gsub('&quot;', '"').gsub('&amp;', '&').gsub('&lt;', '<').gsub('&gt;', '>')
              backtrace << line unless line.empty?
            end

            {
              class_name: decode_html_entities(error_title.strip),
              message: decode_html_entities(error_message&.strip || error_title.strip),
              backtrace: backtrace
            }
          end
        end

        def decode_html_entities(str)
          return str unless str

          str.gsub('&#39;', "'")
             .gsub('&quot;', '"')
             .gsub('&amp;', '&')
             .gsub('&lt;', '<')
             .gsub('&gt;', '>')
             .gsub('&nbsp;', ' ')
        end

        def collect_debug_data_from_info(env, info)
          context = defined?(BrainzLab::Context) ? BrainzLab::Context.current : nil
          collector_data = Data::Collector.get_request_data

          backtrace = (info[:backtrace] || []).map do |line|
            parsed = parse_backtrace_line(line)
            parsed[:in_app] = in_app_frame?(parsed[:file])
            parsed
          end

          # Extract source from the first in-app frame
          source_extract = extract_source_from_backtrace(info[:backtrace] || [])

          {
            exception: nil,
            exception_class: info[:class_name],
            exception_message: info[:message],
            backtrace: backtrace,
            request: build_request_info(env, context),
            context: build_context_info(context),
            sql_queries: collector_data.dig(:database, :queries) || [],
            environment: collect_environment_info,
            source_extract: source_extract
          }
        end

        def render_error_page_from_info(info, data)
          # Create a simple exception-like object
          exception = StandardError.new(info[:message])
          exception.define_singleton_method(:class) do
            Class.new(StandardError) do
              define_singleton_method(:name) { info[:class_name] }
            end
          end

          data[:exception] = exception
          html = @renderer.render(exception, data)

          [
            500,
            {
              'Content-Type' => 'text/html; charset=utf-8',
              'Content-Length' => html.bytesize.to_s,
              'X-Content-Type-Options' => 'nosniff'
            },
            [html]
          ]
        end

        private

        def collect_body(body)
          full_body = +''
          body.each { |part| full_body << part }
          body.close if body.respond_to?(:close)
          full_body
        end

        def should_handle?(env)
          return false unless DevTools.error_page_enabled?
          return false unless DevTools.allowed_environment?
          return false unless DevTools.allowed_ip?(extract_ip(env))

          true
        end

        def extract_ip(env)
          forwarded = env['HTTP_X_FORWARDED_FOR']
          return forwarded.split(',').first.strip if forwarded

          env['REMOTE_ADDR']
        end

        def json_request?(env)
          accept = env['HTTP_ACCEPT'] || ''
          content_type = env['CONTENT_TYPE'] || ''

          accept.include?('application/json') ||
            content_type.include?('application/json') ||
            env['HTTP_X_REQUESTED_WITH'] == 'XMLHttpRequest'
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
            method: request&.request_method || env['REQUEST_METHOD'],
            path: request&.path || env['PATH_INFO'],
            url: request&.url || env['REQUEST_URI'],
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
            if key.start_with?('HTTP_')
              header_name = key.sub('HTTP_', '').split('_').map(&:capitalize).join('-')
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
              '[FILTERED]'
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

          file.include?('/app/') && !file.include?('/vendor/') && !file.include?('/gems/')
        end

        def extract_source_from_backtrace(backtrace_lines)
          return nil if backtrace_lines.empty?

          # Find the first in-app frame
          target_line = backtrace_lines.find { |line| in_app_frame?(line.split(':').first) }
          target_line ||= backtrace_lines.first

          match = target_line.match(/\A(.+):(\d+)/)
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

        def extract_source_lines(exception)
          return nil unless exception.backtrace&.any?

          # Find the first in-app frame (application code, not gems/framework)
          target_line = exception.backtrace.find { |line| in_app_frame?(line.split(':').first) }
          # Fall back to first frame if no in-app frame found
          target_line ||= exception.backtrace.first

          match = target_line.match(/\A(.+):(\d+)/)
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
            rails_version: defined?(::Rails::VERSION::STRING) ? ::Rails::VERSION::STRING : 'N/A',
            ruby_version: RUBY_VERSION,
            env: BrainzLab.configuration.environment,
            server: ENV['SERVER_SOFTWARE'] || 'Unknown',
            pid: Process.pid
          }
        end

        def render_error_page(exception, data)
          html = @renderer.render(exception, data)

          [
            500,
            {
              'Content-Type' => 'text/html; charset=utf-8',
              'Content-Length' => html.bytesize.to_s,
              'X-Content-Type-Options' => 'nosniff'
            },
            [html]
          ]
        end
      end
    end
  end
end
