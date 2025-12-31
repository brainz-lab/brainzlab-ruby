# frozen_string_literal: true

module BrainzLab
  module Utilities
    # Beautiful log formatter for Rails development
    # Provides colorized, structured output with request timing
    #
    # @example Usage in Rails
    #   # config/environments/development.rb
    #   config.log_formatter = BrainzLab::Utilities::LogFormatter.new
    #
    #   # Or use the Rails integration
    #   BrainzLab::Utilities::LogFormatter.install!
    #
    class LogFormatter < ::Logger::Formatter
      COLORS = {
        debug: "\e[36m",    # Cyan
        info: "\e[32m",     # Green
        warn: "\e[33m",     # Yellow
        error: "\e[31m",    # Red
        fatal: "\e[35m",    # Magenta
        reset: "\e[0m",
        dim: "\e[2m",
        bold: "\e[1m",
        blue: "\e[34m",
        gray: "\e[90m"
      }.freeze

      SEVERITY_ICONS = {
        'DEBUG' => '🔍',
        'INFO' => 'ℹ️ ',
        'WARN' => '⚠️ ',
        'ERROR' => '❌',
        'FATAL' => '💀'
      }.freeze

      HTTP_METHODS = {
        'GET' => "\e[32m",     # Green
        'POST' => "\e[33m",    # Yellow
        'PUT' => "\e[34m",     # Blue
        'PATCH' => "\e[34m",   # Blue
        'DELETE' => "\e[31m",  # Red
        'HEAD' => "\e[36m",    # Cyan
        'OPTIONS' => "\e[36m"  # Cyan
      }.freeze

      def initialize(colorize: nil, show_timestamp: true, show_severity: true, compact: false)
        super()
        @colorize = colorize.nil? ? $stdout.tty? : colorize
        @show_timestamp = show_timestamp
        @show_severity = show_severity
        @compact = compact
      end

      def call(severity, timestamp, progname, msg)
        return '' if msg.nil? || msg.to_s.strip.empty?

        message = format_message(msg)
        return '' if skip_message?(message)

        formatted = build_output(severity, timestamp, progname, message)
        "#{formatted}\n"
      end

      # Install as Rails logger formatter
      def self.install!
        return unless defined?(Rails)

        Rails.application.configure do
          config.log_formatter = BrainzLab::Utilities::LogFormatter.new(
            colorize: BrainzLab.configuration.log_formatter_colors,
            compact: BrainzLab.configuration.log_formatter_compact_assets
          )
        end

        # Also hook into ActiveSupport::TaggedLogging if present
        return unless defined?(ActiveSupport::TaggedLogging) && Rails.logger.respond_to?(:formatter=)

        Rails.logger.formatter = new
      end

      private

      def format_message(msg)
        case msg
        when String
          msg
        when Exception
          "#{msg.class}: #{msg.message}\n#{msg.backtrace&.first(10)&.join("\n")}"
        else
          msg.inspect
        end
      end

      def skip_message?(message)
        return false unless BrainzLab.configuration.log_formatter_hide_assets

        # Skip asset pipeline noise
        message.include?('/assets/') ||
          message.include?('Asset pipeline') ||
          message.match?(%r{Started GET "/assets/})
      end

      def build_output(severity, timestamp, _progname, message)
        parts = []

        if @show_timestamp
          ts = colorize(timestamp.strftime('%H:%M:%S.%L'), :gray)
          parts << ts
        end

        if @show_severity
          sev = format_severity(severity)
          parts << sev
        end

        parts << format_content(message, severity)

        parts.join(' ')
      end

      def format_severity(severity)
        icon = SEVERITY_ICONS[severity] || ''
        text = severity.ljust(5)

        if @colorize
          color = severity_color(severity)
          "#{icon}#{color}#{text}#{COLORS[:reset]}"
        else
          "#{icon}[#{text}]"
        end
      end

      def severity_color(severity)
        case severity
        when 'DEBUG' then COLORS[:debug]
        when 'INFO' then COLORS[:info]
        when 'WARN' then COLORS[:warn]
        when 'ERROR' then COLORS[:error]
        when 'FATAL' then COLORS[:fatal]
        else COLORS[:reset]
        end
      end

      def format_content(message, severity)
        # Handle Rails request log patterns
        if (request_match = message.match(/Started (GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) "([^"]+)"/))
          format_request_started(request_match[1], request_match[2])
        elsif (completed_match = message.match(/Completed (\d+) .+ in (\d+(?:\.\d+)?)ms/))
          format_request_completed(completed_match[1].to_i, completed_match[2].to_f)
        elsif message.include?('Processing by')
          format_processing(message)
        elsif message.include?('Parameters:')
          format_parameters(message)
        elsif message.include?('Rendering') || message.include?('Rendered')
          format_rendering(message)
        elsif %w[ERROR FATAL].include?(severity)
          format_error(message)
        else
          message
        end
      end

      def format_request_started(method, path)
        method_color = HTTP_METHODS[method] || COLORS[:reset]

        if @colorize
          "#{COLORS[:bold]}→#{COLORS[:reset]} #{method_color}#{method}#{COLORS[:reset]} #{path}"
        else
          "→ #{method} #{path}"
        end
      end

      def format_request_completed(status, duration)
        status_color = case status
                       when 200..299 then COLORS[:info]
                       when 300..399 then COLORS[:blue]
                       when 400..499 then COLORS[:warn]
                       when 500..599 then COLORS[:error]
                       else COLORS[:reset]
                       end

        duration_color = case duration
                         when 0..100 then COLORS[:info]
                         when 100..500 then COLORS[:warn]
                         else COLORS[:error]
                         end

        if @colorize
          "#{COLORS[:bold]}←#{COLORS[:reset]} #{status_color}#{status}#{COLORS[:reset]} #{duration_color}#{duration.round(1)}ms#{COLORS[:reset]}"
        else
          "← #{status} #{duration.round(1)}ms"
        end
      end

      def format_processing(message)
        if (match = message.match(/Processing by (\w+)#(\w+)/))
          controller, action = match.captures
          if @colorize
            "  #{COLORS[:dim]}#{controller}##{action}#{COLORS[:reset]}"
          else
            "  #{controller}##{action}"
          end
        else
          "  #{message}"
        end
      end

      def format_parameters(message)
        return message unless BrainzLab.configuration.log_formatter_show_params

        if @colorize
          "  #{COLORS[:dim]}#{message}#{COLORS[:reset]}"
        else
          "  #{message}"
        end
      end

      def format_rendering(message)
        if @compact
          # Compact: just show the template name
          if (match = message.match(/Render(?:ed|ing) ([^\s]+)/))
            template = match[1].split('/').last
            if @colorize
              "    #{COLORS[:gray]}#{template}#{COLORS[:reset]}"
            else
              "    #{template}"
            end
          else
            ''
          end
        elsif @colorize
          "    #{COLORS[:dim]}#{message}#{COLORS[:reset]}"
        else
          "    #{message}"
        end
      end

      def format_error(message)
        if @colorize
          "#{COLORS[:error]}#{message}#{COLORS[:reset]}"
        else
          message
        end
      end

      def colorize(text, color)
        return text unless @colorize

        "#{COLORS[color]}#{text}#{COLORS[:reset]}"
      end
    end
  end
end
