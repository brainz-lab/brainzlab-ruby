# frozen_string_literal: true

require "erb"
require "cgi"
require "json"

module BrainzLab
  module DevTools
    module Renderers
      class DebugPanelRenderer
        def initialize
          @template_path = File.join(DevTools::ASSETS_PATH, "templates", "debug_panel.html.erb")
        end

        def render(data)
          template = File.read(@template_path)
          erb = ERB.new(template, trim_mode: "-")

          # Make data available to template
          @data = data
          @timing = data[:timing] || {}
          @request = data[:request] || {}
          @controller = data[:controller] || {}
          @response = data[:response] || {}
          @database = data[:database] || {}
          @views = data[:views] || {}
          @logs = data[:logs] || []
          @memory = data[:memory] || {}
          @user = data[:user]
          @breadcrumbs = data[:breadcrumbs] || []
          @expand_by_default = DevTools.expand_by_default?
          @panel_position = DevTools.panel_position

          erb.result(binding)
        end

        private

        def h(text)
          CGI.escapeHTML(text.to_s)
        end

        def asset_url(file)
          "#{DevTools.asset_path}/#{file}"
        end

        def json_pretty(obj)
          return "" if obj.nil? || (obj.respond_to?(:empty?) && obj.empty?)

          JSON.pretty_generate(obj)
        rescue StandardError
          obj.inspect
        end

        def truncate(text, length = 80)
          return "" unless text

          text = text.to_s
          text.length > length ? "#{text[0...length]}..." : text
        end

        def format_duration(ms)
          return "0ms" unless ms

          if ms >= 1000
            "#{(ms / 1000.0).round(2)}s"
          else
            "#{ms.round(2)}ms"
          end
        end

        def duration_class(ms)
          return "" unless ms

          if ms > 1000
            "very-slow"
          elsif ms > 500
            "slow"
          elsif ms > 200
            "moderate"
          else
            ""
          end
        end

        def query_duration_class(ms)
          return "" unless ms

          if ms > 100
            "very-slow"
          elsif ms > 50
            "slow"
          elsif ms > 10
            "moderate"
          else
            ""
          end
        end

        def status_class(status)
          case status
          when 200..299 then "success"
          when 300..399 then "redirect"
          when 400..499 then "client-error"
          when 500..599 then "server-error"
          else ""
          end
        end

        def log_level_class(level)
          case level.to_s.downcase
          when "error", "fatal" then "error"
          when "warn", "warning" then "warning"
          when "info" then "info"
          when "debug" then "debug"
          else ""
          end
        end

        def format_timestamp(time)
          return "" unless time

          time.strftime("%H:%M:%S.%L")
        end

        def memory_class(delta_mb)
          return "" unless delta_mb

          if delta_mb > 50
            "high"
          elsif delta_mb > 20
            "moderate"
          else
            ""
          end
        end
      end
    end
  end
end
