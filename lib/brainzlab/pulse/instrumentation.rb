# frozen_string_literal: true

module BrainzLab
  module Pulse
    class Instrumentation
      class << self
        def install!
          return unless BrainzLab.configuration.pulse_enabled

          install_active_record!
          install_action_view!
          install_active_support_cache!
          install_action_controller!
          install_http_clients!
          install_active_job!
          install_action_cable!
        end

        private

        # Track SQL queries
        def install_active_record!
          return unless defined?(ActiveRecord)

          ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            next if skip_query?(event.payload)

            sql = event.payload[:sql]
            record_span(
              name: event.payload[:name] || 'SQL',
              kind: 'db',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                sql: truncate_sql(sql),
                name: event.payload[:name],
                cached: event.payload[:cached] || false,
                table: extract_table(sql),
                operation: extract_operation(sql)
              }
            )
          end
        end

        # Track view rendering
        def install_action_view!
          return unless defined?(ActionView)

          ActiveSupport::Notifications.subscribe('render_template.action_view') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)

            record_span(
              name: short_path(event.payload[:identifier]),
              kind: 'render',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                identifier: event.payload[:identifier],
                layout: event.payload[:layout]
              }
            )
          end

          ActiveSupport::Notifications.subscribe('render_partial.action_view') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)

            record_span(
              name: short_path(event.payload[:identifier]),
              kind: 'render',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                identifier: event.payload[:identifier],
                partial: true
              }
            )
          end

          ActiveSupport::Notifications.subscribe('render_collection.action_view') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)

            record_span(
              name: short_path(event.payload[:identifier]),
              kind: 'render',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                identifier: event.payload[:identifier],
                count: event.payload[:count],
                collection: true
              }
            )
          end
        end

        # Track cache operations
        def install_active_support_cache!
          %w[cache_read.active_support cache_write.active_support cache_delete.active_support].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)
              operation = event_name.split('.').first.sub('cache_', '')

              record_span(
                name: "Cache #{operation}",
                kind: 'cache',
                started_at: event.time,
                ended_at: event.end,
                duration_ms: event.duration,
                data: {
                  key: truncate_key(event.payload[:key]),
                  hit: event.payload[:hit],
                  operation: operation
                }
              )
            end
          end
        end

        # Track controller processing for timing breakdown
        def install_action_controller!
          return unless defined?(ActionController)

          ActiveSupport::Notifications.subscribe('process_action.action_controller') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            payload = event.payload

            # Store timing breakdown in thread local for the middleware
            Thread.current[:brainzlab_pulse_breakdown] = {
              view_ms: payload[:view_runtime]&.round(2),
              db_ms: payload[:db_runtime]&.round(2)
            }
          end
        end

        # Track external HTTP requests
        def install_http_clients!
          # Net::HTTP instrumentation
          if defined?(Net::HTTP)
            ActiveSupport::Notifications.subscribe('request.net_http') do |*args|
              event = ActiveSupport::Notifications::Event.new(*args)

              record_span(
                name: "HTTP #{event.payload[:method]} #{event.payload[:host]}",
                kind: 'http',
                started_at: event.time,
                ended_at: event.end,
                duration_ms: event.duration,
                data: {
                  method: event.payload[:method],
                  host: event.payload[:host],
                  path: event.payload[:path],
                  status: event.payload[:code]
                }
              )
            end
          end

          # Faraday instrumentation
          return unless defined?(Faraday)

          ActiveSupport::Notifications.subscribe('request.faraday') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            env = event.payload[:env]
            next unless env

            record_span(
              name: "HTTP #{env.method.to_s.upcase} #{env.url.host}",
              kind: 'http',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                method: env.method.to_s.upcase,
                host: env.url.host,
                path: env.url.path,
                status: env.status
              }
            )
          end
        end

        # Track ActiveJob/SolidQueue
        def install_active_job!
          return unless defined?(ActiveJob)

          # Track job enqueuing
          ActiveSupport::Notifications.subscribe('enqueue.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            job = event.payload[:job]

            record_span(
              name: "Enqueue #{job.class.name}",
              kind: 'job',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                job_class: job.class.name,
                job_id: job.job_id,
                queue: job.queue_name
              }
            )
          end

          # Track job retry
          ActiveSupport::Notifications.subscribe('retry_stopped.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            job = event.payload[:job]
            error = event.payload[:error]

            record_span(
              name: "Retry stopped #{job.class.name}",
              kind: 'job',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              error: true,
              error_class: error&.class&.name,
              error_message: error&.message,
              data: {
                job_class: job.class.name,
                job_id: job.job_id,
                queue: job.queue_name,
                executions: job.executions
              }
            )
          end

          # Track job discard
          ActiveSupport::Notifications.subscribe('discard.active_job') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            job = event.payload[:job]
            error = event.payload[:error]

            record_span(
              name: "Discarded #{job.class.name}",
              kind: 'job',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              error: true,
              error_class: error&.class&.name,
              error_message: error&.message,
              data: {
                job_class: job.class.name,
                job_id: job.job_id,
                queue: job.queue_name,
                executions: job.executions
              }
            )
          end
        end

        # Track ActionCable/SolidCable
        def install_action_cable!
          return unless defined?(ActionCable)

          ActiveSupport::Notifications.subscribe('perform_action.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)

            record_span(
              name: "Cable #{event.payload[:channel_class]}##{event.payload[:action]}",
              kind: 'cable',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                channel: event.payload[:channel_class],
                action: event.payload[:action]
              }
            )
          end

          ActiveSupport::Notifications.subscribe('transmit.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)

            record_span(
              name: "Cable transmit #{event.payload[:channel_class]}",
              kind: 'cable',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                channel: event.payload[:channel_class],
                via: event.payload[:via]
              }
            )
          end

          ActiveSupport::Notifications.subscribe('broadcast.action_cable') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)

            record_span(
              name: "Cable broadcast #{event.payload[:broadcasting]}",
              kind: 'cable',
              started_at: event.time,
              ended_at: event.end,
              duration_ms: event.duration,
              data: {
                broadcasting: event.payload[:broadcasting],
                coder: event.payload[:coder]
              }
            )
          end
        end

        def record_span(name:, kind:, started_at:, ended_at:, duration_ms:, error: false, error_class: nil,
                        error_message: nil, data: {})
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          span = {
            span_id: SecureRandom.uuid,
            name: name,
            kind: kind,
            started_at: started_at,
            ended_at: ended_at,
            duration_ms: duration_ms.round(2),
            data: data.compact
          }

          if error
            span[:error] = true
            span[:error_class] = error_class
            span[:error_message] = error_message
          end

          spans << span
        end

        def skip_query?(payload)
          # Skip SCHEMA queries and internal Rails queries
          return true if payload[:name] == 'SCHEMA'
          return true if payload[:name]&.start_with?('EXPLAIN')
          return true if payload[:sql]&.include?('pg_')
          return true if payload[:sql]&.include?('information_schema')
          return true if payload[:cached] && !include_cached_queries?

          false
        end

        def include_cached_queries?
          false
        end

        def truncate_sql(sql)
          return nil unless sql

          sql.to_s[0, 1000]
        end

        def truncate_key(key)
          return nil unless key

          key.to_s[0, 200]
        end

        def short_path(path)
          return nil unless path

          path.to_s.split('/').last(2).join('/')
        end

        def extract_table(sql)
          return nil unless sql

          # Match FROM "table" or FROM table patterns
          # Also handles INSERT INTO, UPDATE, DELETE FROM
          case sql.to_s
          when /\bFROM\s+["'`]?(\w+)["'`]?/i
            Regexp.last_match(1)
          when /\bINTO\s+["'`]?(\w+)["'`]?/i
            Regexp.last_match(1)
          when /\bUPDATE\s+["'`]?(\w+)["'`]?/i
            Regexp.last_match(1)
          when /\bJOIN\s+["'`]?(\w+)["'`]?/i
            Regexp.last_match(1)
          end
        end

        def extract_operation(sql)
          return nil unless sql

          case sql.to_s.strip.upcase
          when /\ASELECT/i then 'SELECT'
          when /\AINSERT/i then 'INSERT'
          when /\AUPDATE/i then 'UPDATE'
          when /\ADELETE/i then 'DELETE'
          when /\ABEGIN/i, /\ACOMMIT/i, /\AROLLBACK/i then 'TRANSACTION'
          else 'QUERY'
          end
        end
      end
    end
  end
end
