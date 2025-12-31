# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActiveRecord
      SCHEMA_QUERIES = %w[SCHEMA EXPLAIN].freeze
      INTERNAL_TABLES = %w[pg_ information_schema sqlite_ mysql.].freeze

      class << self
        def install!
          return unless defined?(::ActiveRecord)
          return if @installed

          ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            next if skip_query?(event.payload)

            record_breadcrumb(event)
          end

          @installed = true
          BrainzLab.debug_log('ActiveRecord breadcrumbs installed')
        end

        def installed?
          @installed == true
        end

        private

        def record_breadcrumb(event)
          payload = event.payload
          sql = payload[:sql]
          name = payload[:name] || 'SQL'
          duration = event.duration.round(2)

          # Extract operation type from SQL
          operation = extract_operation(sql)

          # Build breadcrumb message
          message = if payload[:cached]
                      "#{name} (cached)"
                    else
                      "#{name} (#{duration}ms)"
                    end

          # Determine level based on duration
          level = if duration > 100
                    :warning
                  elsif duration > 1000
                    :error
                  else
                    :info
                  end

          BrainzLab::Reflex.add_breadcrumb(
            message,
            category: "db.#{operation}",
            level: level,
            data: {
              sql: truncate_sql(sql),
              duration_ms: duration,
              cached: payload[:cached] || false,
              connection_name: extract_connection_name(payload[:connection])
            }.compact
          )
        rescue StandardError => e
          BrainzLab.debug_log("ActiveRecord breadcrumb failed: #{e.message}")
        end

        def extract_operation(sql)
          return 'query' unless sql

          case sql.to_s.strip.upcase
          when /\ASELECT/i then 'select'
          when /\AINSERT/i then 'insert'
          when /\AUPDATE/i then 'update'
          when /\ADELETE/i then 'delete'
          when /\ABEGIN/i, /\ACOMMIT/i, /\AROLLBACK/i then 'transaction'
          else 'query'
          end
        end

        def skip_query?(payload)
          # Skip schema queries
          return true if SCHEMA_QUERIES.include?(payload[:name])

          # Skip internal/system table queries
          sql = payload[:sql].to_s.downcase
          return true if INTERNAL_TABLES.any? { |t| sql.include?(t) }

          # Skip if no SQL (shouldn't happen but be safe)
          return true if payload[:sql].nil? || payload[:sql].empty?

          false
        end

        def extract_connection_name(connection)
          return nil unless connection

          # Rails 8.1+ uses db_config.name on the pool
          # Older versions used connection_class but that's removed in Rails 8.1
          if connection.respond_to?(:pool)
            pool = connection.pool
            pool.db_config.name if pool.respond_to?(:db_config) && pool.db_config.respond_to?(:name)
          elsif connection.respond_to?(:db_config) && connection.db_config.respond_to?(:name)
            connection.db_config.name
          end
        rescue StandardError
          nil
        end

        def truncate_sql(sql)
          return nil unless sql

          truncated = sql.to_s.gsub(/\s+/, ' ').strip
          if truncated.length > 500
            "#{truncated[0, 497]}..."
          else
            truncated
          end
        end
      end
    end
  end
end
