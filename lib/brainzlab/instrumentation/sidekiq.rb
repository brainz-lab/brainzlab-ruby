# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module SidekiqInstrumentation
      @installed = false

      class << self
        def install!
          return unless defined?(::Sidekiq)
          return if @installed

          ::Sidekiq.configure_server do |config|
            config.server_middleware do |chain|
              chain.add ServerMiddleware
            end

            # Also add client middleware for distributed tracing
            config.client_middleware do |chain|
              chain.add ClientMiddleware
            end
          end

          # Client-side middleware for when jobs are enqueued
          ::Sidekiq.configure_client do |config|
            config.client_middleware do |chain|
              chain.add ClientMiddleware
            end
          end

          @installed = true
          BrainzLab.debug_log('Sidekiq instrumentation installed')
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end
      end

      # Server middleware - runs when jobs are processed
      class ServerMiddleware
        def call(worker, job, queue)
          return yield unless should_trace?

          started_at = Time.now.utc
          job_class = job['class'] || worker.class.name
          job_id = job['jid']

          # Calculate queue wait time
          enqueued_at = job['enqueued_at'] ? Time.at(job['enqueued_at']) : nil
          queue_wait_ms = enqueued_at ? ((started_at - enqueued_at) * 1000).round(2) : nil

          # Extract parent trace context if present (distributed tracing)
          parent_context = extract_trace_context(job)

          # Set up context
          setup_context(job, queue)

          # Add breadcrumb
          BrainzLab::Reflex.add_breadcrumb(
            "Sidekiq #{job_class}",
            category: 'job.sidekiq',
            level: :info,
            data: { job_id: job_id, queue: queue, retry_count: job['retry_count'] }
          )

          # Initialize Pulse tracing
          Thread.current[:brainzlab_pulse_spans] = []
          Thread.current[:brainzlab_pulse_breakdown] = nil

          error_occurred = nil
          begin
            yield
          rescue StandardError => e
            error_occurred = e
            raise
          ensure
            record_trace(
              job_class: job_class,
              job_id: job_id,
              queue: queue,
              started_at: started_at,
              queue_wait_ms: queue_wait_ms,
              retry_count: job['retry_count'] || 0,
              parent_context: parent_context,
              error: error_occurred
            )

            cleanup_context
          end
        end

        private

        def should_trace?
          BrainzLab.configuration.pulse_enabled
        end

        def setup_context(job, queue)
          BrainzLab::Context.current.set_context(
            job_class: job['class'],
            job_id: job['jid'],
            queue_name: queue,
            retry_count: job['retry_count'],
            arguments: job['args']&.map(&:to_s)&.first(5)
          )
        end

        def cleanup_context
          Thread.current[:brainzlab_pulse_spans] = nil
          Thread.current[:brainzlab_pulse_breakdown] = nil
          BrainzLab::Context.clear!
          BrainzLab::Pulse::Propagation.clear!
        end

        def extract_trace_context(job)
          return nil unless job['_brainzlab_trace']

          trace_data = job['_brainzlab_trace']
          BrainzLab::Pulse::Propagation::Context.new(
            trace_id: trace_data['trace_id'],
            span_id: trace_data['span_id'],
            sampled: trace_data['sampled'] != false
          )
        rescue StandardError
          nil
        end

        def record_trace(job_class:, job_id:, queue:, started_at:, queue_wait_ms:, retry_count:, parent_context:,
                         error:)
          ended_at = Time.now.utc
          duration_ms = ((ended_at - started_at) * 1000).round(2)

          # Collect spans
          spans = Thread.current[:brainzlab_pulse_spans] || []
          breakdown = Thread.current[:brainzlab_pulse_breakdown] || {}

          formatted_spans = spans.map do |span|
            {
              span_id: span[:span_id],
              name: span[:name],
              kind: span[:kind],
              started_at: format_timestamp(span[:started_at]),
              ended_at: format_timestamp(span[:ended_at]),
              duration_ms: span[:duration_ms],
              data: span[:data],
              error: span[:error],
              error_class: span[:error_class],
              error_message: span[:error_message]
            }.compact
          end

          payload = {
            trace_id: SecureRandom.uuid,
            name: job_class,
            kind: 'job',
            started_at: started_at.utc.iso8601(3),
            ended_at: ended_at.utc.iso8601(3),
            duration_ms: duration_ms,
            job_class: job_class,
            job_id: job_id,
            queue: queue,
            queue_wait_ms: queue_wait_ms,
            executions: retry_count + 1,
            db_ms: breakdown[:db_ms],
            error: error.present?,
            error_class: error&.class&.name,
            error_message: error&.message&.slice(0, 1000),
            spans: formatted_spans,
            environment: BrainzLab.configuration.environment,
            commit: BrainzLab.configuration.commit,
            host: BrainzLab.configuration.host
          }

          # Add parent trace info for distributed tracing
          if parent_context&.valid?
            payload[:parent_trace_id] = parent_context.trace_id
            payload[:parent_span_id] = parent_context.span_id
          end

          BrainzLab::Pulse.client.send_trace(payload.compact)
        rescue StandardError => e
          BrainzLab.debug_log("Sidekiq trace recording failed: #{e.message}")
        end

        def format_timestamp(ts)
          return nil unless ts

          case ts
          when Time, DateTime then ts.utc.iso8601(3)
          when Float, Integer then Time.at(ts).utc.iso8601(3)
          when String then ts
          else ts.to_s
          end
        end
      end

      # Client middleware - runs when jobs are enqueued
      class ClientMiddleware
        def call(_worker_class, job, queue, _redis_pool)
          # Inject trace context for distributed tracing
          inject_trace_context(job)

          # Add breadcrumb for job enqueue
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Enqueue #{job['class']}",
              category: 'job.sidekiq.enqueue',
              level: :info,
              data: { queue: queue, job_id: job['jid'] }
            )
          end

          # Record span for Pulse
          record_enqueue_span(job, queue)

          yield
        end

        private

        def inject_trace_context(job)
          return unless BrainzLab.configuration.pulse_enabled

          # Get or create propagation context
          ctx = BrainzLab::Pulse::Propagation.current
          ctx ||= BrainzLab::Pulse.send(:create_propagation_context)

          return unless ctx&.valid?

          job['_brainzlab_trace'] = {
            'trace_id' => ctx.trace_id,
            'span_id' => ctx.span_id,
            'sampled' => ctx.sampled
          }
        rescue StandardError => e
          BrainzLab.debug_log("Failed to inject Sidekiq trace context: #{e.message}")
        end

        def record_enqueue_span(job, queue)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          spans << {
            span_id: SecureRandom.uuid,
            name: "Enqueue #{job['class']}",
            kind: 'job',
            started_at: Time.now.utc,
            ended_at: Time.now.utc,
            duration_ms: 0,
            data: {
              job_class: job['class'],
              job_id: job['jid'],
              queue: queue
            }
          }
        end
      end
    end
  end
end
