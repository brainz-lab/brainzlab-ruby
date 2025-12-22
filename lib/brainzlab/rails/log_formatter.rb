# frozen_string_literal: true

module BrainzLab
  module Rails
    class LogFormatter
      ASSET_PATHS = %w[/assets /packs /vite /images /fonts /stylesheets /javascripts].freeze
      ASSET_EXTENSIONS = %w[.css .js .map .png .jpg .jpeg .gif .svg .ico .woff .woff2 .ttf .eot].freeze
      SIMPLE_PATHS = %w[/up /health /healthz /ready /readiness /live /liveness /ping /favicon.ico /apple-touch-icon.png /apple-touch-icon-precomposed.png /robots.txt /sitemap.xml].freeze
      IGNORED_PATHS = %w[/apple-touch-icon.png /apple-touch-icon-precomposed.png /favicon.ico].freeze

      # Thresholds for highlighting
      SLOW_QUERY_MS = 5.0
      N_PLUS_ONE_THRESHOLD = 3

      # ANSI color codes
      COLORS = {
        reset: "\e[0m",
        bold: "\e[1m",
        dim: "\e[2m",
        red: "\e[31m",
        green: "\e[32m",
        yellow: "\e[33m",
        blue: "\e[34m",
        magenta: "\e[35m",
        cyan: "\e[36m",
        white: "\e[37m",
        gray: "\e[90m"
      }.freeze

      # Box drawing characters
      BOX = {
        top_left: "┌",
        top_right: "─",
        bottom_left: "└",
        bottom_right: "─",
        vertical: "│",
        horizontal: "─"
      }.freeze

      attr_reader :config

      def initialize(config = {})
        @config = default_config.merge(config)
        @request_data = {}
      end

      def default_config
        {
          enabled: true,
          colors: $stdout.tty?,
          hide_assets: false,
          hide_ignored: true,
          compact_assets: true,
          show_params: true,
          show_sql_count: true,
          show_sql_details: true,
          show_views: true,
          slow_query_threshold: SLOW_QUERY_MS,
          n_plus_one_threshold: N_PLUS_ONE_THRESHOLD,
          line_width: detect_terminal_width
        }
      end

      def detect_terminal_width
        # Try to get terminal width, fallback to 120
        width = ENV["COLUMNS"]&.to_i
        return width if width && width > 0

        if $stdout.tty? && IO.respond_to?(:console) && IO.console
          _rows, cols = IO.console.winsize
          return cols if cols > 0
        end

        120 # Default to 120 for wider output
      rescue
        120
      end

      # Called when a request starts
      def start_request(request_id, data = {})
        @request_data[request_id] = {
          started_at: Time.current,
          method: data[:method],
          path: data[:path],
          params: data[:params] || {},
          controller: nil,
          action: nil,
          status: nil,
          duration: nil,
          view_runtime: nil,
          db_runtime: nil,
          sql_queries: [],
          views: [],
          error: nil,
          error_message: nil
        }
      end

      # Called when controller processes action
      def process_action(request_id, data = {})
        return unless @request_data[request_id]

        @request_data[request_id].merge!(
          controller: data[:controller],
          action: data[:action],
          status: data[:status],
          duration: data[:duration],
          view_runtime: data[:view_runtime],
          db_runtime: data[:db_runtime]
        )
      end

      # Called when SQL query is executed
      def sql_query(request_id, name: nil, duration: 0, sql: nil, sql_pattern: nil, cached: false, source: nil)
        return unless @request_data[request_id]

        @request_data[request_id][:sql_queries] << {
          name: name,
          duration: duration,
          sql: sql,
          sql_pattern: sql_pattern,
          cached: cached,
          source: source
        }
      end

      # Called when template is rendered
      def render_template(request_id, template: nil, duration: 0, layout: nil)
        return unless @request_data[request_id]

        @request_data[request_id][:views] << {
          type: :template,
          template: template,
          duration: duration,
          layout: layout
        }
      end

      # Called when partial is rendered
      def render_partial(request_id, template: nil, duration: 0, count: nil)
        return unless @request_data[request_id]

        @request_data[request_id][:views] << {
          type: :partial,
          template: template,
          duration: duration,
          count: count
        }
      end

      # Called when layout is rendered
      def render_layout(request_id, layout: nil, duration: 0)
        return unless @request_data[request_id]

        @request_data[request_id][:views] << {
          type: :layout,
          template: layout,
          duration: duration
        }
      end

      # Called when an error occurs
      def error(request_id, exception)
        return unless @request_data[request_id]

        @request_data[request_id][:error] = exception.class.name
        @request_data[request_id][:error_message] = exception.message
      end

      # Called when request ends - returns formatted output
      def end_request(request_id)
        data = @request_data.delete(request_id)
        return nil unless data

        format_request(data)
      end

      # Format a complete request
      def format_request(data)
        return nil if should_ignore?(data)
        return format_simple(data) if should_be_simple?(data)

        format_full(data)
      end

      private

      def should_ignore?(data)
        return false unless config[:hide_ignored]

        path = data[:path].to_s.downcase
        IGNORED_PATHS.any? { |p| path == p || path.end_with?(p) }
      end

      def should_be_simple?(data)
        return true if asset_request?(data[:path])
        return true if simple_path?(data[:path])

        false
      end

      def asset_request?(path)
        return false unless path

        path = path.to_s.downcase
        return true if ASSET_PATHS.any? { |p| path.start_with?(p) }
        return true if ASSET_EXTENSIONS.any? { |ext| path.end_with?(ext) }

        false
      end

      def simple_path?(path)
        return false unless path

        path = path.to_s.downcase
        SIMPLE_PATHS.include?(path)
      end

      # Format: 09:13:23  GET  /assets/app.css  →  200  3ms
      def format_simple(data)
        return nil if config[:hide_assets] && asset_request?(data[:path])

        time = format_time(data[:started_at])
        method = format_method(data[:method])
        path = truncate(data[:path], 40)
        status = format_status(data[:status])
        duration = format_duration(data[:duration])

        parts = [
          colorize(time, :gray),
          method,
          colorize(path, :white),
          colorize("→", :gray),
          status,
          duration
        ]

        parts.join("  ") + "\n"
      end

      # Format full block output
      def format_full(data)
        lines = []
        width = config[:line_width]

        # Header line
        method_path = "#{data[:method]} #{data[:path]}"
        header = build_header(method_path, data[:error], width)
        lines << header

        # Status line
        status_text = data[:status] ? "#{data[:status]} #{status_phrase(data[:status])}" : "---"
        lines << build_line("status", format_status_value(data[:status], status_text))

        # Duration line
        if data[:duration]
          lines << build_line("duration", format_duration_full(data[:duration]))
        end

        # Database line with query analysis
        if data[:db_runtime] || data[:sql_queries].any?
          db_info = format_db_info(data)
          lines << build_line("db", db_info)
        end

        # Views line
        if data[:view_runtime]
          lines << build_line("views", "#{data[:view_runtime].round(1)}ms")
        end

        # Params line (if enabled and present)
        if config[:show_params] && data[:params].present?
          params_str = format_params(data[:params])
          lines << build_line("params", params_str) if params_str
        end

        # Error lines
        if data[:error]
          lines << build_line("error", colorize(data[:error], :red))
          if data[:error_message]
            msg = truncate(data[:error_message], width - 15)
            lines << build_line("message", colorize("\"#{msg}\"", :red))
          end
        end

        # SQL details section (N+1, slow queries)
        if config[:show_sql_details]
          sql_issues = analyze_sql_queries(data[:sql_queries])
          if sql_issues.any?
            lines << build_separator(width)
            sql_issues.each { |issue| lines << issue }
          end
        end

        # View rendering details
        if config[:show_views] && data[:views].any?
          view_summary = format_view_summary(data[:views])
          if view_summary.any?
            lines << build_separator(width) unless sql_issues&.any?
            view_summary.each { |line| lines << line }
          end
        end

        # Footer line
        lines << build_footer(width)

        lines.join("\n") + "\n\n"
      end

      def analyze_sql_queries(queries)
        issues = []
        threshold = config[:slow_query_threshold] || SLOW_QUERY_MS
        n1_threshold = config[:n_plus_one_threshold] || N_PLUS_ONE_THRESHOLD

        # Group queries by pattern to detect N+1
        pattern_counts = queries.reject { |q| q[:cached] }.group_by { |q| q[:sql_pattern] }

        pattern_counts.each do |pattern, matching_queries|
          next unless matching_queries.size >= n1_threshold
          next unless pattern # Skip if no pattern

          # This is a potential N+1
          sample = matching_queries.first
          source = sample[:source] || "unknown"
          name = sample[:name] || "Query"

          # Extract table name from pattern
          table_match = pattern.match(/FROM "?(\w+)"?/i)
          table = table_match ? table_match[1] : name

          issues << build_line("", colorize("N+1", :red) + " " +
            colorize("#{table} × #{matching_queries.size}", :yellow) +
            colorize(" (#{source})", :gray))
        end

        # Find slow queries (not cached, not already reported as N+1)
        n1_patterns = pattern_counts.select { |_, qs| qs.size >= n1_threshold }.keys
        slow_queries = queries.reject { |q| q[:cached] || n1_patterns.include?(q[:sql_pattern]) }
                              .select { |q| q[:duration] && q[:duration] >= threshold }
                              .sort_by { |q| -q[:duration] }
                              .first(3)

        slow_queries.each do |query|
          source = query[:source] || "unknown"
          name = query[:name] || "Query"
          duration = query[:duration].round(1)

          issues << build_line("", colorize("Slow", :yellow) + " " +
            colorize("#{name} #{duration}ms", :white) +
            colorize(" (#{source})", :gray))
        end

        issues
      end

      def format_view_summary(views)
        lines = []

        # Find the main template and layout
        templates = views.select { |v| v[:type] == :template }
        partials = views.select { |v| v[:type] == :partial }

        # Group partials by name to detect repeated renders
        partial_counts = partials.group_by { |p| p[:template] }

        templates.each do |template|
          duration = template[:duration] ? " (#{template[:duration].round(1)}ms)" : ""
          lines << build_line("", colorize("View", :cyan) + " " +
            colorize(template[:template], :white) +
            colorize(duration, :gray))
        end

        # Show partials that were rendered multiple times (potential issue)
        partial_counts.each do |name, renders|
          next if renders.size < 3 # Only show if rendered 3+ times

          total_duration = renders.sum { |r| r[:duration] || 0 }
          lines << build_line("", colorize("Partial", :yellow) + " " +
            colorize("#{name} × #{renders.size}", :white) +
            colorize(" (#{total_duration.round(1)}ms total)", :gray))
        end

        lines
      end

      def build_header(text, has_error, width)
        prefix = "#{BOX[:top_left]}#{BOX[:horizontal]} "
        suffix = has_error ? " #{BOX[:horizontal]} ERROR #{BOX[:horizontal]}" : " "

        available = width - prefix.length - suffix.length
        text = truncate(text, available)
        padding = BOX[:horizontal] * [available - text.length, 0].max

        header = "#{prefix}#{text} #{padding}#{suffix}"
        header = header[0..width] if header.length > width + 1

        if has_error
          colorize(header, :red)
        else
          colorize(header, :cyan)
        end
      end

      def build_line(key, value)
        prefix = colorize("#{BOX[:vertical]}  ", :cyan)
        if key.empty?
          "#{prefix}#{value}"
        else
          key_formatted = colorize(key.ljust(8), :gray)
          "#{prefix}#{key_formatted} = #{value}"
        end
      end

      def build_separator(width)
        colorize("#{BOX[:vertical]}  #{BOX[:horizontal] * (width - 4)}", :cyan)
      end

      def build_footer(width)
        footer = "#{BOX[:bottom_left]}#{BOX[:horizontal] * (width - 1)}"
        colorize(footer, :cyan)
      end

      def format_time(time)
        return "--:--:--" unless time

        time.strftime("%H:%M:%S")
      end

      def format_method(method)
        method = method.to_s.upcase
        color = case method
                when "GET" then :green
                when "POST" then :blue
                when "PUT", "PATCH" then :yellow
                when "DELETE" then :red
                else :white
                end
        colorize(method.ljust(6), color)
      end

      def format_status(status)
        return colorize("---", :gray) unless status

        color = case status
                when 200..299 then :green
                when 300..399 then :cyan
                when 400..499 then :yellow
                when 500..599 then :red
                else :white
                end
        colorize(status.to_s, color)
      end

      def format_status_value(status, text)
        color = case status
                when 200..299 then :green
                when 300..399 then :cyan
                when 400..499 then :yellow
                when 500..599 then :red
                else :white
                end
        colorize(text, color)
      end

      def format_duration(ms)
        return colorize("--", :gray) unless ms

        formatted = if ms < 1
                      "<1ms"
                    elsif ms < 1000
                      "#{ms.round}ms"
                    else
                      "#{(ms / 1000.0).round(1)}s"
                    end

        color = if ms < 100
                  :green
                elsif ms < 500
                  :yellow
                else
                  :red
                end
        colorize(formatted, color)
      end

      def format_duration_full(ms)
        formatted = format_duration(ms)
        # Remove color codes for comparison
        ms_value = ms || 0
        if ms_value < 100
          formatted
        elsif ms_value < 500
          "#{formatted} #{colorize('(slow)', :yellow)}"
        else
          "#{formatted} #{colorize('(very slow)', :red)}"
        end
      end

      def format_db_info(data)
        parts = []

        if data[:db_runtime]
          parts << "#{data[:db_runtime].round(1)}ms"
        end

        if config[:show_sql_count]
          queries = data[:sql_queries] || []
          total = queries.size
          cached = queries.count { |q| q[:cached] }
          non_cached = total - cached

          query_text = "#{non_cached} #{non_cached == 1 ? 'query' : 'queries'}"
          if cached.positive?
            query_text += ", #{cached} cached"
          end
          parts << "(#{query_text})"
        end

        parts.join(" ")
      end

      def format_params(params)
        return nil if params.empty?

        # Filter out controller and action
        filtered = params.except("controller", "action", :controller, :action)
        return nil if filtered.empty?

        # Truncate large values
        simplified = simplify_params(filtered)
        str = simplified.inspect
        truncate(str, config[:line_width] - 20)
      end

      def simplify_params(obj, depth = 0)
        return "..." if depth > 2

        case obj
        when Hash
          obj.transform_values { |v| simplify_params(v, depth + 1) }
        when Array
          if obj.length > 3
            obj.first(3).map { |v| simplify_params(v, depth + 1) } + ["...(#{obj.length - 3} more)"]
          else
            obj.map { |v| simplify_params(v, depth + 1) }
          end
        when String
          obj.length > 50 ? "#{obj[0..47]}..." : obj
        else
          obj
        end
      end

      def status_phrase(status)
        Rack::Utils::HTTP_STATUS_CODES[status] || "Unknown"
      end

      def truncate(text, length)
        return text if text.nil? || text.length <= length

        "#{text[0..(length - 4)]}..."
      end

      def colorize(text, color)
        return text unless config[:colors]
        return text unless COLORS[color]

        "#{COLORS[color]}#{text}#{COLORS[:reset]}"
      end
    end
  end
end
