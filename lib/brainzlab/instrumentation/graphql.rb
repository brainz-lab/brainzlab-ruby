# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module GraphQLInstrumentation
      @installed = false

      class << self
        def install!
          return unless defined?(::GraphQL::Schema)
          return if @installed

          # For GraphQL Ruby 2.0+
          if ::GraphQL::Schema.respond_to?(:trace_with)
            # Will be installed per-schema via BrainzLab::GraphQL::Tracer
            BrainzLab.debug_log('GraphQL tracer available - add `trace_with BrainzLab::Instrumentation::GraphQLInstrumentation::Tracer` to your schema')
          end

          # Subscribe to ActiveSupport notifications if available
          install_notifications!

          @installed = true
          BrainzLab.debug_log('GraphQL instrumentation installed')
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end

        private

        def install_notifications!
          # GraphQL-ruby emits ActiveSupport notifications
          ActiveSupport::Notifications.subscribe('execute.graphql') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_execution(event)
          end

          ActiveSupport::Notifications.subscribe('analyze.graphql') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_analyze(event)
          end

          ActiveSupport::Notifications.subscribe('validate.graphql') do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            record_validate(event)
          end
        rescue StandardError => e
          BrainzLab.debug_log("GraphQL notifications setup failed: #{e.message}")
        end

        def record_execution(event)
          payload = event.payload
          query = payload[:query]
          operation_name = query&.operation_name || 'anonymous'
          operation_type = query&.selected_operation&.operation_type || 'query'
          duration_ms = event.duration.round(2)

          # Add breadcrumb
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "GraphQL #{operation_type} #{operation_name}",
              category: 'graphql.execute',
              level: payload[:errors]&.any? ? :error : :info,
              data: {
                operation_name: operation_name,
                operation_type: operation_type,
                duration_ms: duration_ms,
                error_count: payload[:errors]&.size || 0
              }.compact
            )
          end

          # Record span
          record_span(
            name: "GraphQL #{operation_type} #{operation_name}",
            kind: 'graphql',
            duration_ms: duration_ms,
            started_at: event.time,
            ended_at: event.end,
            data: {
              operation_name: operation_name,
              operation_type: operation_type,
              query: truncate_query(query&.query_string),
              variables: sanitize_variables(query&.variables&.to_h),
              error_count: payload[:errors]&.size || 0
            }.compact,
            error: payload[:errors]&.any?
          )
        rescue StandardError => e
          BrainzLab.debug_log("GraphQL execution recording failed: #{e.message}")
        end

        def record_analyze(event)
          record_span(
            name: 'GraphQL analyze',
            kind: 'graphql',
            duration_ms: event.duration.round(2),
            started_at: event.time,
            ended_at: event.end,
            data: { phase: 'analyze' }
          )
        rescue StandardError => e
          BrainzLab.debug_log("GraphQL analyze recording failed: #{e.message}")
        end

        def record_validate(event)
          record_span(
            name: 'GraphQL validate',
            kind: 'graphql',
            duration_ms: event.duration.round(2),
            started_at: event.time,
            ended_at: event.end,
            data: { phase: 'validate' }
          )
        rescue StandardError => e
          BrainzLab.debug_log("GraphQL validate recording failed: #{e.message}")
        end

        def record_span(name:, kind:, duration_ms:, started_at:, ended_at:, data:, error: false)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          spans << {
            span_id: SecureRandom.uuid,
            name: name,
            kind: kind,
            started_at: started_at,
            ended_at: ended_at,
            duration_ms: duration_ms,
            data: data,
            error: error
          }
        end

        def truncate_query(query)
          return nil unless query

          query.to_s[0, 2000]
        end

        def sanitize_variables(variables)
          return nil unless variables

          scrub_fields = BrainzLab.configuration.scrub_fields
          variables.transform_values do |value|
            if scrub_fields.any? { |f| value.to_s.downcase.include?(f.to_s) }
              '[FILTERED]'
            else
              value
            end
          end
        rescue StandardError
          nil
        end
      end

      # GraphQL Ruby 2.0+ Tracer module
      # Add to your schema: trace_with BrainzLab::Instrumentation::GraphQLInstrumentation::Tracer
      module Tracer
        def execute_query(query:)
          started_at = Time.now.utc
          operation_name = query.operation_name || 'anonymous'
          operation_type = query.selected_operation&.operation_type || 'query'

          result = super

          duration_ms = ((Time.now.utc - started_at) * 1000).round(2)
          has_errors = result.to_h['errors']&.any?

          # Add breadcrumb
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "GraphQL #{operation_type} #{operation_name}",
              category: 'graphql.execute',
              level: has_errors ? :error : :info,
              data: {
                operation_name: operation_name,
                operation_type: operation_type,
                duration_ms: duration_ms
              }
            )
          end

          # Record span
          spans = Thread.current[:brainzlab_pulse_spans]
          if spans
            spans << {
              span_id: SecureRandom.uuid,
              name: "GraphQL #{operation_type} #{operation_name}",
              kind: 'graphql',
              started_at: started_at,
              ended_at: Time.now.utc,
              duration_ms: duration_ms,
              data: {
                operation_name: operation_name,
                operation_type: operation_type
              },
              error: has_errors
            }
          end

          result
        rescue StandardError => e
          # Record error
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "GraphQL #{operation_type} #{operation_name} failed",
              category: 'graphql.error',
              level: :error,
              data: { error: e.class.name }
            )
          end
          raise
        end

        def execute_field(field:, query:, ast_node:, arguments:, object:)
          started_at = Time.now.utc

          result = super

          duration_ms = ((Time.now.utc - started_at) * 1000).round(2)

          # Only track slow field resolutions (> 10ms) to avoid noise
          if duration_ms > 10
            spans = Thread.current[:brainzlab_pulse_spans]
            if spans
              spans << {
                span_id: SecureRandom.uuid,
                name: "GraphQL field #{field.owner.graphql_name}.#{field.graphql_name}",
                kind: 'graphql.field',
                started_at: started_at,
                ended_at: Time.now.utc,
                duration_ms: duration_ms,
                data: {
                  field: field.graphql_name,
                  parent_type: field.owner.graphql_name
                }
              }
            end
          end

          result
        end
      end
    end
  end
end
