# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class ActiveSupportCache
      # Thresholds for slow cache operations (in milliseconds)
      SLOW_CACHE_THRESHOLD = 10
      VERY_SLOW_CACHE_THRESHOLD = 50

      class << self
        def install!
          return unless defined?(::ActiveSupport::Cache)
          return if @installed

          install_cache_read_subscriber!
          install_cache_read_multi_subscriber!
          install_cache_write_subscriber!
          install_cache_write_multi_subscriber!
          install_cache_delete_subscriber!
          install_cache_exist_subscriber!
          install_cache_fetch_hit_subscriber!
          install_cache_generate_subscriber!
          install_cache_increment_subscriber!
          install_cache_decrement_subscriber!
          install_cache_delete_multi_subscriber!
          install_cache_delete_matched_subscriber!
          install_cache_cleanup_subscriber!
          install_cache_prune_subscriber!
          install_message_serializer_fallback_subscriber!

          @installed = true
          BrainzLab.debug_log('ActiveSupport::Cache instrumentation installed')
        end

        def installed?
          @installed == true
        end

        private

        # ============================================
        # Cache Read
        # ============================================
        def install_cache_read_subscriber!
          ActiveSupport::Notifications.subscribe('cache_read.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_read(event)
          end
        end

        def handle_cache_read(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          hit = payload[:hit]
          super_operation = payload[:super_operation]

          # Skip if this is part of a fetch operation (will be tracked separately)
          return if super_operation == :fetch

          # Record breadcrumb
          record_cache_breadcrumb('read', key, duration, hit: hit)

          # Add Pulse span
          record_cache_span(event, 'read', key, duration, hit: hit)

          # Track cache metrics
          track_cache_metrics('read', hit, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache read instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Read Multi
        # ============================================
        def install_cache_read_multi_subscriber!
          ActiveSupport::Notifications.subscribe('cache_read_multi.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_read_multi(event)
          end
        end

        def handle_cache_read_multi(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key] # Array of keys
          hits = payload[:hits] # Keys that were found
          super_operation = payload[:super_operation]

          return if super_operation == :fetch_multi

          key_count = Array(key).size
          hit_count = Array(hits).size

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache read_multi: #{hit_count}/#{key_count} hits (#{duration}ms)",
              category: 'cache.read_multi',
              level: duration >= SLOW_CACHE_THRESHOLD ? :warning : :info,
              data: {
                key_count: key_count,
                hit_count: hit_count,
                miss_count: key_count - hit_count,
                duration_ms: duration,
                hit_rate: key_count > 0 ? (hit_count.to_f / key_count * 100).round(1) : 0
              }
            )
          end

          # Add Pulse span
          record_cache_span(event, 'read_multi', "#{key_count} keys", duration,
                            key_count: key_count, hit_count: hit_count)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache read_multi instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Write
        # ============================================
        def install_cache_write_subscriber!
          ActiveSupport::Notifications.subscribe('cache_write.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_write(event)
          end
        end

        def handle_cache_write(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          # Record breadcrumb
          record_cache_breadcrumb('write', key, duration)

          # Add Pulse span
          record_cache_span(event, 'write', key, duration)

          # Log slow writes
          log_slow_cache_operation('write', key, duration) if duration >= SLOW_CACHE_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache write instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Write Multi
        # ============================================
        def install_cache_write_multi_subscriber!
          ActiveSupport::Notifications.subscribe('cache_write_multi.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_write_multi(event)
          end
        end

        def handle_cache_write_multi(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key] # Hash of key => value pairs
          key_count = key.is_a?(Hash) ? key.size : 1

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache write_multi: #{key_count} keys (#{duration}ms)",
              category: 'cache.write_multi',
              level: duration >= SLOW_CACHE_THRESHOLD ? :warning : :info,
              data: {
                key_count: key_count,
                duration_ms: duration
              }
            )
          end

          # Add Pulse span
          record_cache_span(event, 'write_multi', "#{key_count} keys", duration, key_count: key_count)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache write_multi instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Delete
        # ============================================
        def install_cache_delete_subscriber!
          ActiveSupport::Notifications.subscribe('cache_delete.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_delete(event)
          end
        end

        def handle_cache_delete(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          # Record breadcrumb
          record_cache_breadcrumb('delete', key, duration)

          # Add Pulse span
          record_cache_span(event, 'delete', key, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache delete instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Exist?
        # ============================================
        def install_cache_exist_subscriber!
          ActiveSupport::Notifications.subscribe('cache_exist?.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_exist(event)
          end
        end

        def handle_cache_exist(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          # Only track if slow or significant
          return if duration < 1

          # Add Pulse span (skip breadcrumb for exist? as it's noisy)
          record_cache_span(event, 'exist', key, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache exist? instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Fetch Hit (successful fetch from cache)
        # ============================================
        def install_cache_fetch_hit_subscriber!
          ActiveSupport::Notifications.subscribe('cache_fetch_hit.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_fetch_hit(event)
          end
        end

        def handle_cache_fetch_hit(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          # Record breadcrumb
          record_cache_breadcrumb('fetch', key, duration, hit: true)

          # Add Pulse span
          record_cache_span(event, 'fetch', key, duration, hit: true)

          # Track cache metrics
          track_cache_metrics('fetch', true, duration)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache fetch_hit instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Generate (cache miss, value computed)
        # ============================================
        def install_cache_generate_subscriber!
          ActiveSupport::Notifications.subscribe('cache_generate.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_generate(event)
          end
        end

        def handle_cache_generate(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]

          # Record breadcrumb - this is a cache miss that triggered computation
          if BrainzLab.configuration.reflex_effectively_enabled?
            level = case duration
                    when 0...SLOW_CACHE_THRESHOLD then :info
                    when SLOW_CACHE_THRESHOLD...VERY_SLOW_CACHE_THRESHOLD then :warning
                    else :error
                    end

            BrainzLab::Reflex.add_breadcrumb(
              "Cache miss + generate: #{truncate_key(key)} (#{duration}ms)",
              category: 'cache.generate',
              level: level,
              data: {
                key: truncate_key(key),
                duration_ms: duration,
                hit: false
              }
            )
          end

          # Add Pulse span
          record_cache_span(event, 'generate', key, duration, hit: false)

          # Track cache metrics
          track_cache_metrics('fetch', false, duration)

          # Log slow cache generations
          log_slow_cache_operation('generate', key, duration) if duration >= SLOW_CACHE_THRESHOLD
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache generate instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Increment
        # ============================================
        def install_cache_increment_subscriber!
          ActiveSupport::Notifications.subscribe('cache_increment.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_increment(event)
          end
        end

        def handle_cache_increment(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          amount = payload[:amount]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache increment: #{truncate_key(key)} by #{amount} (#{duration}ms)",
              category: 'cache.increment',
              level: :info,
              data: {
                key: truncate_key(key),
                amount: amount,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_cache_span(event, 'increment', key, duration, amount: amount)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache increment instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Decrement
        # ============================================
        def install_cache_decrement_subscriber!
          ActiveSupport::Notifications.subscribe('cache_decrement.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_decrement(event)
          end
        end

        def handle_cache_decrement(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          amount = payload[:amount]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache decrement: #{truncate_key(key)} by #{amount} (#{duration}ms)",
              category: 'cache.decrement',
              level: :info,
              data: {
                key: truncate_key(key),
                amount: amount,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_cache_span(event, 'decrement', key, duration, amount: amount)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache decrement instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Delete Multi
        # ============================================
        def install_cache_delete_multi_subscriber!
          ActiveSupport::Notifications.subscribe('cache_delete_multi.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_delete_multi(event)
          end
        end

        def handle_cache_delete_multi(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key] # Array of keys
          key_count = Array(key).size

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache delete_multi: #{key_count} keys (#{duration}ms)",
              category: 'cache.delete_multi',
              level: :info,
              data: {
                key_count: key_count,
                duration_ms: duration
              }
            )
          end

          # Add Pulse span
          record_cache_span(event, 'delete_multi', "#{key_count} keys", duration, key_count: key_count)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache delete_multi instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Delete Matched (pattern-based delete)
        # ============================================
        def install_cache_delete_matched_subscriber!
          ActiveSupport::Notifications.subscribe('cache_delete_matched.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_delete_matched(event)
          end
        end

        def handle_cache_delete_matched(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key] # Pattern

          # Record breadcrumb - pattern deletes are significant
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache delete_matched: #{truncate_key(key)} (#{duration}ms)",
              category: 'cache.delete_matched',
              level: :warning,
              data: {
                pattern: truncate_key(key),
                duration_ms: duration
              }
            )
          end

          # Add Pulse span
          record_cache_span(event, 'delete_matched', key, duration)

          # Log pattern deletes
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.info(
              "Cache pattern delete",
              pattern: truncate_key(key),
              duration_ms: duration
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache delete_matched instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Cleanup (remove expired entries)
        # ============================================
        def install_cache_cleanup_subscriber!
          ActiveSupport::Notifications.subscribe('cache_cleanup.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_cleanup(event)
          end
        end

        def handle_cache_cleanup(event)
          payload = event.payload
          duration = event.duration.round(2)

          size = payload[:size]
          key = payload[:key]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache cleanup: size=#{size} (#{duration}ms)",
              category: 'cache.cleanup',
              level: :info,
              data: {
                size: size,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_cache_span(event, 'cleanup', 'cleanup', duration, size: size)
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache cleanup instrumentation failed: #{e.message}")
        end

        # ============================================
        # Cache Prune (reduce cache size)
        # ============================================
        def install_cache_prune_subscriber!
          ActiveSupport::Notifications.subscribe('cache_prune.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_cache_prune(event)
          end
        end

        def handle_cache_prune(event)
          payload = event.payload
          duration = event.duration.round(2)

          key = payload[:key]
          from = payload[:from]
          to = payload[:to]

          # Record breadcrumb
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Cache prune: #{from} -> #{to} (#{duration}ms)",
              category: 'cache.prune',
              level: :info,
              data: {
                from: from,
                to: to,
                duration_ms: duration
              }.compact
            )
          end

          # Add Pulse span
          record_cache_span(event, 'prune', 'prune', duration, from: from, to: to)

          # Log prune operations
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.info(
              "Cache pruned",
              from: from,
              to: to,
              duration_ms: duration
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport::Cache prune instrumentation failed: #{e.message}")
        end

        # ============================================
        # Message Serializer Fallback
        # Fired when a message is deserialized using a fallback serializer
        # This typically indicates a migration between serialization formats
        # ============================================
        def install_message_serializer_fallback_subscriber!
          ActiveSupport::Notifications.subscribe('message_serializer_fallback.active_support') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            handle_message_serializer_fallback(event)
          end
        end

        def handle_message_serializer_fallback(event)
          payload = event.payload
          duration = event.duration.round(2)

          serializer = payload[:serializer]
          fallback = payload[:fallback]
          serialized = payload[:serialized]
          deserialized = payload[:deserialized]

          # Record breadcrumb - this is a warning as it indicates a format mismatch
          if BrainzLab.configuration.reflex_effectively_enabled?
            BrainzLab::Reflex.add_breadcrumb(
              "Message serializer fallback: #{serializer} -> #{fallback}",
              category: 'serializer.fallback',
              level: :warning,
              data: {
                serializer: serializer.to_s,
                fallback: fallback.to_s,
                duration_ms: duration
              }.compact
            )
          end

          # Log to Recall - this is significant for debugging serialization issues
          if BrainzLab.configuration.recall_effectively_enabled?
            BrainzLab::Recall.warn(
              "Message serializer fallback used",
              serializer: serializer.to_s,
              fallback: fallback.to_s,
              duration_ms: duration
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("ActiveSupport message_serializer_fallback instrumentation failed: #{e.message}")
        end

        # ============================================
        # Recording Helpers
        # ============================================
        def record_cache_breadcrumb(operation, key, duration, hit: nil)
          return unless BrainzLab.configuration.reflex_effectively_enabled?

          level = duration >= SLOW_CACHE_THRESHOLD ? :warning : :info

          message = if hit.nil?
                      "Cache #{operation}: #{truncate_key(key)} (#{duration}ms)"
                    elsif hit
                      "Cache #{operation} hit: #{truncate_key(key)} (#{duration}ms)"
                    else
                      "Cache #{operation} miss: #{truncate_key(key)} (#{duration}ms)"
                    end

          data = {
            key: truncate_key(key),
            operation: operation,
            duration_ms: duration
          }
          data[:hit] = hit unless hit.nil?

          BrainzLab::Reflex.add_breadcrumb(
            message,
            category: "cache.#{operation}",
            level: level,
            data: data.compact
          )
        end

        def record_cache_span(event, operation, key, duration, hit: nil, **extra)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          tracer = BrainzLab::Pulse.tracer
          return unless tracer.current_trace

          span_data = {
            span_id: SecureRandom.uuid,
            name: "cache.#{operation}",
            kind: 'cache',
            started_at: event.time,
            ended_at: event.end,
            duration_ms: duration,
            error: false,
            data: {
              'cache.operation' => operation,
              'cache.key' => truncate_key(key),
              'cache.hit' => hit
            }.merge(extra.transform_keys { |k| "cache.#{k}" }).compact
          }

          tracer.current_spans << span_data
        end

        def track_cache_metrics(operation, hit, duration)
          return unless BrainzLab.configuration.pulse_effectively_enabled?

          # Increment cache operation counter
          BrainzLab::Pulse.counter(
            "cache.#{operation}.total",
            1,
            tags: { hit: hit.to_s }
          )

          # Record cache operation duration
          BrainzLab::Pulse.histogram(
            "cache.#{operation}.duration_ms",
            duration,
            tags: { hit: hit.to_s }
          )
        end

        def log_slow_cache_operation(operation, key, duration)
          return unless BrainzLab.configuration.recall_effectively_enabled?

          level = duration >= VERY_SLOW_CACHE_THRESHOLD ? :error : :warn

          BrainzLab::Recall.send(
            level,
            "Slow cache #{operation}: #{truncate_key(key)} (#{duration}ms)",
            operation: operation,
            key: truncate_key(key),
            duration_ms: duration,
            threshold_exceeded: duration >= VERY_SLOW_CACHE_THRESHOLD ? 'critical' : 'warning'
          )
        end

        # ============================================
        # Helper Methods
        # ============================================
        def truncate_key(key, max_length = 100)
          return 'unknown' unless key

          key_str = key.to_s
          if key_str.length > max_length
            "#{key_str[0, max_length - 3]}..."
          else
            key_str
          end
        end
      end
    end
  end
end
