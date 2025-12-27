# frozen_string_literal: true

require "erb"
require "cgi"

module BrainzLab
  module DevTools
    module Renderers
      class ErrorPageRenderer
        def initialize
          @template_path = File.join(DevTools::ASSETS_PATH, "templates", "error_page.html.erb")
        end

        def render(exception, data)
          template = File.read(@template_path)
          erb = ERB.new(template, trim_mode: "-")

          # Make data available to template
          @exception = exception
          @data = data
          @backtrace = data[:backtrace] || []
          @request = data[:request] || {}
          @context = data[:context] || {}
          @sql_queries = data[:sql_queries] || []
          @environment = data[:environment] || {}
          @source_extract = data[:source_extract]

          erb.result(binding)
        end

        private

        def h(text)
          CGI.escapeHTML(text.to_s)
        end

        def asset_url(file)
          "#{DevTools.asset_path}/#{file}"
        end

        def format_params(params, indent = 0)
          return "" if params.nil? || params.empty?

          lines = []
          prefix = "  " * indent

          params.each do |key, value|
            if value.is_a?(Hash)
              lines << "#{prefix}#{h(key)}:"
              lines << format_params(value, indent + 1)
            elsif value.is_a?(Array)
              lines << "#{prefix}#{h(key)}: #{h(value.inspect)}"
            else
              lines << "#{prefix}#{h(key)}: #{h(value)}"
            end
          end

          lines.join("\n")
        end

        def truncate(text, length = 100)
          return "" unless text

          text.length > length ? "#{text[0...length]}..." : text
        end

        def time_ago(time)
          return "unknown" unless time

          seconds = Time.now.utc - time
          case seconds
          when 0..59 then "#{seconds.to_i}s ago"
          when 60..3599 then "#{(seconds / 60).to_i}m ago"
          else "#{(seconds / 3600).to_i}h ago"
          end
        end
      end
    end
  end
end
