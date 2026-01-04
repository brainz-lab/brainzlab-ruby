# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActiveRecord
      SCHEMA_QUERIES = %w[SCHEMA EXPLAIN].freeze
      INTERNAL_TABLES = %w[pg_ information_schema sqlite_ mysql.].freeze

      # Thresholds for slow query detection (in milliseconds)
      SLOW_QUERY_THRESHOLD = 100
      VERY_SLOW_QUERY_THRESHOLD = 1000

      # N+1 detection settings
      N_PLUS_ONE_THRESHOLD = 5 # queries to same table in single request
      N_PLUS_ONE_WINDOW = 50   # max queries to track per request

      class << self
        def install!
          return unless defined?(::ActiveRecord)
          return if @installed

          install_sql_subscriber!
          install_instantiation_subscriber!
          install_transaction_subscribers!
          install_strict_loading_subscriber!
          install_deprecated_association_subscriber!

          @installed = true
          BrainzLab.debug_log('ActiveRecord instrumentation installed (sql, instantiation, transactions, strict_loading)')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # SQL Query Instrumentation
        # ============================================
        def install_sql_subscriber!
          ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            next if skip_query?(event.payload)

            handle_sql_event(event)
          end
        end

        def handle_sql_event(event)
          payload = event.payload
          duration = event.duration.round(2)

          # Record breadcrumb for Reflex (enhanced)
          record_sql_breadcrumb(event, duration)

          # Add span to Pulse (APM)
          record_sql_span(event, duration)

          # Log slow queries to Recall
          log_slow_query(event, duration) if duration >= SLOW_QUERY_THRESHOLD

          # Track for N+1 detection
          track_query_for_n_plus_one(event)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveRecord SQL instrumentation failed: #{e.message}")
        end

        def record_sql_breadcrumb(event, duration)
          payload = event.payload
          sql = payload[:sql]
          name = payload[:name] || 'SQL'
          operation = extract_operation(sql)

          message = if payload[:cached]
                      "#{name} (cached)"
                    else
                      "#{name} (#{duration}ms)"
                    end

          # Determine level based on duration
          level = case duration
                  when 0...SLOW_QUERY_THRESHOLD then :info
                  when SLOW_QUERY_THRESHOLD...VERY_SLOW_QUERY_THRESHOLD then :warning
                  else :error
                  end

          BrainzLab::Reflex.add_breadcrumb(
            message,
            category: "db.#{operation}",
            level: level,
            data: {
              sql: truncate_sql(sql),
              duration_ms: duration,
              cached: payload[:cached] || false,
              async: payload[:async] || false,
              row_count: payload[:row_count],
              affected_rows: payload[:affected_rows],
              connection_name: extract_connection_name(payload[:connection])
            }.compact
          )
        end

        def record_sql_span(event, duration)
          # Only add spans if Pulse is enabled and there's an active trace
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          payload = event.payload
          sql = payload[:sql]
          operation = extract_operation(sql)
          name = payload[:name] || 'SQL'

          # Build span data
          span_data = {
            span_id: SecureRandom.uuid,
            name: "db.#{operation}",
            kind: 'db',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'db.system' => extract_adapter_name(payload[:connection]),
              'db.name' => extract_database_name(payload[:connection]),
              'db.statement' => truncate_sql(sql, 1000),
              'db.operation' => operation,
              'db.query_name' => name,
              'db.cached' => payload[:cached] || false,
              'db.async' => payload[:async] || false,
              'db.row_count' => payload[:row_count],
              'db.affected_rows' => payload[:affected_rows]
            }.compact
          }

          tracer.current_spans << span_data
        end

        def log_slow_query(event, duration)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          payload = event.payload
          sql = payload[:sql]
          operation = extract_operation(sql)
          name = payload[:name] || 'SQL'

          level = duration >= VERY_SLOW_QUERY_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow SQL query: #{name} (#{duration}ms)",
            sql: truncate_sql(sql, 2000),
            duration_ms: duration,
            operation: operation,
            cached: payload[:cached] || false,
            row_count: payload[:row_count],
            affected_rows: payload[:affected_rows],
            connection_name: extract_connection_name(payload[:connection]),
            threshold_exceeded: duration >= VERY_SLOW_QUERY_THRESHOLD ? 'critical' : 'warning'
          )
        end

        # ============================================
        # N+1 Query Detection
        # ============================================
        def track_query_for_n_plus_one(event)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          payload = event.payload
          sql = payload[:sql].to_s

          # Extract table name from SELECT queries
          table = extract_table_from_sql(sql)
          return unless table

          # Track queries per table in current request
          query_tracker = Thread.current[:brainzlab_query_tracker] ||= {}
          query_tracker[table] ||= { count: 0, queries: [] }

          tracker = query_tracker[table]
          tracker[:count] += 1

          # Store sample queries (limited)
          if tracker[:queries].size < 3
            tracker[:queries] << truncate_sql(sql, 200)
          end

          # Detect N+1 pattern
          if tracker[:count] == N_PLUS_ONE_THRESHOLD
            report_n_plus_one(table, tracker)
          end
        end

        def report_n_plus_one(table, tracker)
          BrainzLab::Reflex.add_breadcrumb(
            "Potential N+1 detected: #{tracker[:count]}+ queries to '#{table}'",
            category: 'db.n_plus_one',
            level: :warning,
            data: {
              table: table,
              query_count: tracker[:count],
              sample_queries: tracker[:queries]
            }
          )

          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Potential N+1 query detected",
              table: table,
              query_count: tracker[:count],
              sample_queries: tracker[:queries]
            )
          end
        end

        def clear_n_plus_one_tracker!
          Thread.current[:brainzlab_query_tracker] = nil
        end

        # ============================================
        # Record Instantiation (for N+1 metrics)
        # ============================================
        def install_instantiation_subscriber!
          ActiveSupport::Notifications.subscribe('instantiation.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_instantiation_event(event)
          end
        end

        def handle_instantiation_event(event)
          payload = event.payload
          record_count = payload[:record_count]
          class_name = payload[:class_name]
          duration = event.duration.round(2)

          # Track instantiation metrics for Pulse
          if BrainzLab.configuration.pulse_effectively_enabled?
            tracer = BrainzLab::Pulse.tracer
            if tracer.current_trace
              span_data = {
                span_id: SecureRandom.uuid,
                name: "db.instantiate.#{class_name}",
                kind: 'db',
                started_at: event.time,
                ended_at: event.end,
                duration_ms: duration,
                error: false,
                data: {
                  'db.operation' => 'instantiate',
                  'db.model' => class_name,
                  'db.record_count' => record_count
                }
              }

              tracer.current_spans << span_data
            end
          end

          # Add breadcrumb for large instantiations
          if record_count >= 100
            BrainzLab::Reflex.add_breadcrumb(
              "Instantiated #{record_count} #{class_name} records",
              category: 'db.instantiate',
              level: record_count >= 1000 ? :warning : :info,
              data: {
                class_name: class_name,
                record_count: record_count,
                duration_ms: duration
              }
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveRecord instantiation instrumentation failed: #{e.message}")
        end

        # ============================================
        # Transaction Tracking
        # ============================================
        def install_transaction_subscribers!
          # Track transaction start
          ActiveSupport::Notifications.subscribe('start_transaction.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_transaction_start(event)
          end

          # Track transaction completion
          ActiveSupport::Notifications.subscribe('transaction.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_transaction_complete(event)
          end
        end

        def handle_transaction_start(event)
          # Store transaction start time for duration calculation
          transaction = event.payload[:transaction]
          return unless transaction

          Thread.current[:brainzlab_transaction_starts] ||= {}
          Thread.current[:brainzlab_transaction_starts][transaction.object_id] = event.time
        rescue StandardError => e
          BrainzLab.debug_log("ActiveRecord transaction start instrumentation failed: #{e.message}")
        end

        def handle_transaction_complete(event)
          payload = event.payload
          transaction = payload[:transaction]
          outcome = payload[:outcome] # :commit, :rollback, :restart, :incomplete

          # Calculate duration from stored start time
          starts = Thread.current[:brainzlab_transaction_starts] || {}
          start_time = starts.delete(transaction&.object_id) || event.time
          duration = ((event.end - start_time) * 1000).round(2)

          connection_name = extract_connection_name(payload[:connection])

          # Add breadcrumb
          level = case outcome
                  when :commit then :info
                  when :rollback then :warning
                  when :restart, :incomplete then :error
                  else :info
                  end

          BrainzLab::Reflex.add_breadcrumb(
            "Transaction #{outcome} (#{duration}ms)",
            category: 'db.transaction',
            level: level,
            data: {
              outcome: outcome.to_s,
              duration_ms: duration,
              connection_name: connection_name
            }.compact
          )

          # Add Pulse span
          if BrainzLab.configuration.pulse_effectively_enabled?
            tracer = BrainzLab::Pulse.tracer
            if tracer.current_trace
              span_data = {
                span_id: SecureRandom.uuid,
                name: 'db.transaction',
                kind: 'db',
                started_at: start_time,
                ended_at: event.end,
                duration_ms: duration,
                error: outcome != :commit,
                data: {
                  'db.operation' => 'transaction',
                  'db.transaction.outcome' => outcome.to_s,
                  'db.name' => connection_name
                }.compact
              }

              tracer.current_spans << span_data
            end
          end

          # Log rollbacks and errors to Recall
          if outcome != :commit && BrainzLab.configuration.recall_effectively_enabled?
            log_level = outcome == :rollback ? :warn : :error
            BrainzLab::Recall.send(
              log_level,
              "Database transaction #{outcome}",
              outcome: outcome.to_s,
              duration_ms: duration,
              connection_name: connection_name
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveRecord transaction instrumentation failed: #{e.message}")
        end

        # ============================================
        # Strict Loading Violation Tracking
        # ============================================
        def install_strict_loading_subscriber!
          ActiveSupport::Notifications.subscribe('strict_loading_violation.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_strict_loading_violation(event)
          end
        end

        def handle_strict_loading_violation(event)
          payload = event.payload
          owner = payload[:owner]
          reflection = payload[:reflection]

          owner_class = owner.is_a?(Class) ? owner.name : owner.class.name
          association_name = reflection.respond_to?(:name) ? reflection.name : reflection.to_s

          # Add breadcrumb
          BrainzLab::Reflex.add_breadcrumb(
            "Strict loading violation: #{owner_class}##{association_name}",
            category: 'db.strict_loading',
            level: :warning,
            data: {
              owner_class: owner_class,
              association: association_name.to_s,
              reflection_type: reflection.class.name
            }
          )

          # Log to Recall
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Strict loading violation detected",
              owner_class: owner_class,
              association: association_name.to_s,
              message: "Attempted to lazily load #{association_name} on #{owner_class} with strict_loading enabled"
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveRecord strict loading instrumentation failed: #{e.message}")
        end

        # ============================================
        # Deprecated Association Tracking
        # Fired when a deprecated association is accessed
        # ============================================
        def install_deprecated_association_subscriber!
          ActiveSupport::Notifications.subscribe('deprecated_association.active_record') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_deprecated_association(event)
          end
        end

        def handle_deprecated_association(event)
          payload = event.payload
          owner = payload[:owner]
          reflection = payload[:reflection]
          message = payload[:message]

          owner_class = owner.is_a?(Class) ? owner.name : owner.class.name
          association_name = reflection.respond_to?(:name) ? reflection.name : reflection.to_s

          # Add breadcrumb
          BrainzLab::Reflex.add_breadcrumb(
            "Deprecated association: #{owner_class}##{association_name}",
            category: 'db.deprecated_association',
            level: :warning,
            data: {
              owner_class: owner_class,
              association: association_name.to_s,
              message: message&.slice(0, 200)
            }.compact
          )

          # Log to Recall
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Deprecated association accessed",
              owner_class: owner_class,
              association: association_name.to_s,
              message: message
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveRecord deprecated association instrumentation failed: #{e.message}")
        end

        # ============================================
        # Helper Methods
        # ============================================
        def extract_operation(sql)
          return 'query' unless sql

          case sql.to_s.strip
          when /\ASELECT/i then 'select'
          when /\AINSERT/i then 'insert'
          when /\AUPDATE/i then 'update'
          when /\ADELETE/i then 'delete'
          when /\ABEGIN/i, /\ASTART TRANSACTION/i then 'transaction.begin'
          when /\ACOMMIT/i then 'transaction.commit'
          when /\AROLLBACK TO SAVEPOINT/i then 'savepoint.rollback'
          when /\AROLLBACK/i then 'transaction.rollback'
          when /\ARELEASE SAVEPOINT/i then 'savepoint.release'
          when /\ASAVEPOINT/i then 'savepoint'
          else 'query'
          end
        end

        def extract_table_from_sql(sql)
          # Extract table name from SELECT queries for N+1 detection
          # Handles: SELECT ... FROM table_name, SELECT ... FROM "table_name", etc.
          return nil unless sql =~ /\ASELECT/i

          if sql =~ /FROM\s+["'`]?(\w+)["'`]?/i
            ::Regexp.last_match(1)
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
          if connection.respond_to?(:pool)
            pool = connection.pool
            pool.db_config.name if pool.respond_to?(:db_config) && pool.db_config.respond_to?(:name)
          elsif connection.respond_to?(:db_config) && connection.db_config.respond_to?(:name)
            connection.db_config.name
          end
        rescue StandardError
          nil
        end

        def extract_adapter_name(connection)
          return nil unless connection

          if connection.respond_to?(:adapter_name)
            connection.adapter_name.downcase
          elsif connection.respond_to?(:pool) && connection.pool.respond_to?(:db_config)
            connection.pool.db_config.adapter
          end
        rescue StandardError
          nil
        end

        def extract_database_name(connection)
          return nil unless connection

          if connection.respond_to?(:pool) && connection.pool.respond_to?(:db_config)
            connection.pool.db_config.database
          elsif connection.respond_to?(:current_database)
            connection.current_database
          end
        rescue StandardError
          nil
        end

        def truncate_sql(sql, max_length = 500)
          return nil unless sql

          truncated = sql.to_s.gsub(/\s+/, ' ').strip
          if truncated.length > max_length
            "#{truncated[0, max_length - 3]}..."
          else
            truncated
          end
        end
      end
    end
  end
end
