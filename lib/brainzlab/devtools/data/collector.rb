# frozen_string_literal: true

module BrainzLab
  module DevTools
    module Data
      class Collector
        THREAD_KEY = :brainzlab_devtools_data

        class << self
          def start_request(env)
            Thread.current[THREAD_KEY] = {
              started_at: Time.now.utc,
              sql_queries: [],
              views: [],
              logs: [],
              memory_before: get_memory_usage,
              env: env
            }

            subscribe_to_events
          end

          def end_request
            unsubscribe_from_events
            data = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = nil
            data
          end

          def active?
            !Thread.current[THREAD_KEY].nil?
          end

          def get_request_data
            data = Thread.current[THREAD_KEY] || {}
            return {} if data.empty?

            context = defined?(BrainzLab::Context) ? BrainzLab::Context.current : nil
            duration_ms = data[:started_at] ? ((Time.now.utc - data[:started_at]) * 1000).round(2) : 0

            {
              timing: {
                started_at: data[:started_at],
                duration_ms: duration_ms
              },
              request: build_request_data(data, context),
              controller: build_controller_data(context),
              database: build_database_data(data[:sql_queries] || []),
              views: build_views_data(data[:views] || []),
              logs: data[:logs] || [],
              memory: build_memory_data(data),
              user: context&.user,
              breadcrumbs: context&.breadcrumbs&.to_a || []
            }
          end

          def add_sql_query(name:, duration:, sql:, cached: false, source: nil)
            data = Thread.current[THREAD_KEY]
            return unless data

            data[:sql_queries] << {
              name: name,
              duration: duration.round(2),
              sql: sql,
              sql_pattern: normalize_sql(sql),
              cached: cached,
              source: source,
              timestamp: Time.now.utc
            }
          end

          def add_view(type:, template:, duration:, layout: nil)
            data = Thread.current[THREAD_KEY]
            return unless data

            data[:views] << {
              type: type,
              template: template,
              duration: duration.round(2),
              layout: layout,
              timestamp: Time.now.utc
            }
          end

          def add_log(level:, message:, log_data: nil)
            request_data = Thread.current[THREAD_KEY]
            return unless request_data

            request_data[:logs] << {
              level: level,
              message: message,
              data: log_data,
              timestamp: Time.now.utc
            }
          end

          private

          def build_request_data(data, context)
            env = data[:env] || {}
            request = env["action_dispatch.request"] || (defined?(ActionDispatch::Request) ? ActionDispatch::Request.new(env) : nil)

            {
              method: context&.request_method || env["REQUEST_METHOD"],
              path: context&.request_path || env["PATH_INFO"],
              url: context&.request_url || env["REQUEST_URI"],
              params: context&.request_params || {},
              headers: extract_headers(env),
              request_id: context&.request_id || env["action_dispatch.request_id"]
            }
          end

          def build_controller_data(context)
            {
              name: context&.controller,
              action: context&.action
            }
          end

          def build_database_data(queries)
            {
              queries: queries,
              total_count: queries.length,
              cached_count: queries.count { |q| q[:cached] },
              total_duration_ms: queries.sum { |q| q[:duration] || 0 }.round(2),
              n_plus_ones: detect_n_plus_ones(queries)
            }
          end

          def build_views_data(views)
            {
              templates: views,
              total_count: views.length,
              total_duration_ms: views.sum { |v| v[:duration] || 0 }.round(2)
            }
          end

          def build_memory_data(data)
            current_memory = get_memory_usage
            before_memory = data[:memory_before] || 0

            {
              before_mb: before_memory,
              after_mb: current_memory,
              delta_mb: (current_memory - before_memory).round(2)
            }
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

          def subscribe_to_events
            return unless defined?(ActiveSupport::Notifications)

            @sql_subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              next if event.payload[:name] == "SCHEMA"
              next if event.payload[:sql]&.start_with?("PRAGMA")

              add_sql_query(
                name: event.payload[:name],
                duration: event.duration,
                sql: event.payload[:sql],
                cached: event.payload[:cached] || event.payload[:name] == "CACHE",
                source: extract_source(caller)
              )
            end

            @view_subscriber = ActiveSupport::Notifications.subscribe(/render_.+\.action_view/) do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              type = event.name.include?("partial") ? :partial : :template

              add_view(
                type: type,
                template: event.payload[:identifier],
                duration: event.duration,
                layout: event.payload[:layout]
              )
            end
          end

          def unsubscribe_from_events
            return unless defined?(ActiveSupport::Notifications)

            ActiveSupport::Notifications.unsubscribe(@sql_subscriber) if @sql_subscriber
            ActiveSupport::Notifications.unsubscribe(@view_subscriber) if @view_subscriber
            @sql_subscriber = nil
            @view_subscriber = nil
          end

          def detect_n_plus_ones(queries)
            non_cached = queries.reject { |q| q[:cached] }
            pattern_groups = non_cached.group_by { |q| q[:sql_pattern] }

            pattern_groups.select { |_, qs| qs.size >= 3 }.map do |pattern, matching|
              {
                pattern: pattern,
                count: matching.size,
                total_duration_ms: matching.sum { |q| q[:duration] || 0 }.round(2),
                sample_query: matching.first[:sql],
                source: matching.first[:source]
              }
            end
          end

          def normalize_sql(sql)
            return nil unless sql

            sql.gsub(/\b\d+\b/, "?")
               .gsub(/'[^']*'/, "?")
               .gsub(/"[^"]*"/, "?")
               .gsub(/\$\d+/, "?")
               .gsub(%r{/\*.*?\*/}, "")
               .gsub(/\s+/, " ")
               .strip
          end

          def get_memory_usage
            `ps -o rss= -p #{Process.pid}`.to_i / 1024.0
          rescue StandardError
            0
          end

          def extract_source(backtrace)
            backtrace.each do |line|
              next if line.include?("/brainzlab")
              next if line.include?("/gems/")
              next if line.include?("/ruby/")

              if line.include?("/app/")
                match = line.match(%r{(app/[^:]+:\d+)})
                return match[1] if match
              end
            end
            nil
          end
        end
      end
    end
  end
end
