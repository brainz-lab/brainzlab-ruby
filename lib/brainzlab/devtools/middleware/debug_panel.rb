# frozen_string_literal: true

module BrainzLab
  module DevTools
    module Middleware
      class DebugPanel
        HTML_CONTENT_TYPE = "text/html"

        def initialize(app)
          @app = app
          @renderer = Renderers::DebugPanelRenderer.new
        end

        def call(env)
          return @app.call(env) unless should_inject?(env)

          # Start collecting data
          Data::Collector.start_request(env)

          begin
            status, headers, body = @app.call(env)

            # Only inject into HTML responses
            if injectable_response?(status, headers)
              body = inject_panel(body, env, status, headers)
              headers = update_content_length(headers, body)
            end

            [status, headers, body]
          ensure
            Data::Collector.end_request
          end
        end

        private

        def should_inject?(env)
          return false unless DevTools.debug_panel_enabled?
          return false unless DevTools.allowed_environment?
          return false unless DevTools.allowed_ip?(extract_ip(env))
          return false if asset_request?(env["PATH_INFO"])
          return false if devtools_asset_request?(env["PATH_INFO"])
          return false if turbo_stream_request?(env)

          true
        end

        def extract_ip(env)
          forwarded = env["HTTP_X_FORWARDED_FOR"]
          return forwarded.split(",").first.strip if forwarded

          env["REMOTE_ADDR"]
        end

        def injectable_response?(status, headers)
          return false unless status == 200

          content_type = headers["Content-Type"]
          return false unless content_type

          content_type.include?(HTML_CONTENT_TYPE)
        end

        def asset_request?(path)
          return true if path.nil?

          asset_paths = %w[/assets /packs /vite]
          asset_extensions = %w[.js .css .map .png .jpg .jpeg .gif .svg .ico .woff .woff2 .ttf .eot]

          asset_paths.any? { |p| path.start_with?(p) } ||
            asset_extensions.any? { |ext| path.end_with?(ext) }
        end

        def devtools_asset_request?(path)
          return false if path.nil?

          path.start_with?(DevTools.asset_path)
        end

        def turbo_stream_request?(env)
          accept = env["HTTP_ACCEPT"] || ""
          accept.include?("text/vnd.turbo-stream.html")
        end

        def inject_panel(body, env, status, headers)
          # Collect all response body parts
          full_body = collect_body(body)

          # Get collected data
          data = Data::Collector.get_request_data
          data[:response] = {
            status: status,
            headers: headers.to_h,
            content_type: headers["Content-Type"]
          }

          # Render panel HTML
          panel_html = @renderer.render(data)

          # Inject before </body>
          if full_body.include?("</body>")
            full_body = full_body.sub("</body>", "#{panel_html}</body>")
          else
            # If no </body> tag, append at the end
            full_body = "#{full_body}#{panel_html}"
          end

          [full_body]
        end

        def collect_body(body)
          full_body = +""
          body.each { |part| full_body << part }
          body.close if body.respond_to?(:close)
          full_body
        end

        def update_content_length(headers, body)
          headers = headers.to_h.dup
          headers["Content-Length"] = body.sum(&:bytesize).to_s
          headers
        end
      end
    end
  end
end
