# frozen_string_literal: true

module BrainzLab
  module DevTools
    module Middleware
      class AssetServer
        MIME_TYPES = {
          ".css" => "text/css; charset=utf-8",
          ".js" => "application/javascript; charset=utf-8",
          ".svg" => "image/svg+xml",
          ".png" => "image/png",
          ".woff2" => "font/woff2"
        }.freeze

        def initialize(app)
          @app = app
        end

        def call(env)
          return @app.call(env) unless DevTools.enabled?

          path = env["PATH_INFO"]
          asset_prefix = DevTools.asset_path

          if path.start_with?("#{asset_prefix}/")
            serve_asset(path.sub("#{asset_prefix}/", ""))
          else
            @app.call(env)
          end
        end

        private

        def serve_asset(relative_path)
          # Prevent directory traversal
          return not_found if relative_path.include?("..")

          file_path = File.join(DevTools::ASSETS_PATH, relative_path)
          return not_found unless File.exist?(file_path)

          ext = File.extname(relative_path)
          content_type = MIME_TYPES[ext] || "application/octet-stream"
          content = File.read(file_path)

          [
            200,
            {
              "Content-Type" => content_type,
              "Content-Length" => content.bytesize.to_s,
              "Cache-Control" => "public, max-age=31536000",
              "X-Content-Type-Options" => "nosniff"
            },
            [content]
          ]
        end

        def not_found
          [404, { "Content-Type" => "text/plain" }, ["Not Found"]]
        end
      end
    end
  end
end
