# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module DelayedJobInstrumentation
      @installed = false

      class << self
        def install!
          return unless defined?(::Delayed::Job) || defined?(::Delayed::Backend)
          return if @installed

          # Install lifecycle hooks
          if defined?(::Delayed::Worker)
            install_lifecycle_hooks!
          end

          # Install plugin if Delayed::Plugin is available
          if defined?(::Delayed::Plugin)
            ::Delayed::Worker.plugins << Plugin
          end

          @installed = true
          BrainzLab.debug_log("Delayed::Job instrumentation installed")
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end

        private

        def install_lifecycle_hooks!
          ::Delayed::Worker.lifecycle.around(:invoke_job) do |job, *args, &block|
            around_invoke(job, &block)
          end

          ::Delayed::Worker.lifecycle.after(:error) do |worker, job|
            record_error(job)
          end

          ::Delayed::Worker.lifecycle.after(:failure) do |worker, job|
            record_failure(job)
          end
        rescue StandardError => e
          BrainzLab.debug_log("Delayed::Job lifecycle hooks failed: #{e.message}")
        end

        def around_invoke(job, &block)
          started_at = Time.now.utc
          job_name = extract_job_name(job)
          queue = job.queue || "default"

          # Calculate queue wait time
          queue_wait_ms = job.created_at ? ((started_at - job.created_at) * 1000).round(2) : nil

          # Set up context
          setup_context(job, queue)

          # Add breadcrumb
          BrainzLab::Reflex.add_breadcrumb(
            "DelayedJob #{job_name}",
            category: "job.delayed_job",
            level: :info,
            data: { job_id: job.id, queue: queue, attempts: job.attempts }
          )

          # Initialize Pulse tracing
          Thread.current[:brainzlab_pulse_spans] = []
          Thread.current[:brainzlab_pulse_breakdown] = nil

          error_occurred = nil
          begin
            block.call(job)
          rescue StandardError => e
            error_occurred = e
            raise
          ensure
            record_trace(
              job: job,
              job_name: job_name,
              queue: queue,
              started_at: started_at,
              queue_wait_ms: queue_wait_ms,
              error: error_occurred
            )

            cleanup_context
          end
        end

        def setup_context(job, queue)
          BrainzLab::Context.current.set_context(
            job_class: extract_job_name(job),
            job_id: job.id,
            queue_name: queue,
            attempts: job.attempts
          )
        end

        def cleanup_context
          Thread.current[:brainzlab_pulse_spans] = nil
          Thread.current[:brainzlab_pulse_breakdown] = nil
          BrainzLab::Context.clear!
        end

        def record_trace(job:, job_name:, queue:, started_at:, queue_wait_ms:, error:)
          return unless BrainzLab.configuration.pulse_enabled

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
              data: span[:data]
            }.compact
          end

          payload = {
            trace_id: SecureRandom.uuid,
            name: job_name,
            kind: "job",
            started_at: started_at.utc.iso8601(3),
            ended_at: ended_at.utc.iso8601(3),
            duration_ms: duration_ms,
            job_class: job_name,
            job_id: job.id.to_s,
            queue: queue,
            queue_wait_ms: queue_wait_ms,
            executions: (job.attempts || 0) + 1,
            db_ms: breakdown[:db_ms],
            error: error.present?,
            error_class: error&.class&.name,
            error_message: error&.message&.slice(0, 1000),
            spans: formatted_spans,
            environment: BrainzLab.configuration.environment,
            commit: BrainzLab.configuration.commit,
            host: BrainzLab.configuration.host
          }

          BrainzLab::Pulse.client.send_trace(payload.compact)
        rescue StandardError => e
          BrainzLab.debug_log("Delayed::Job trace recording failed: #{e.message}")
        end

        def record_error(job)
          return unless job.last_error

          BrainzLab::Reflex.add_breadcrumb(
            "DelayedJob error: #{extract_job_name(job)}",
            category: "job.delayed_job.error",
            level: :error,
            data: {
              job_id: job.id,
              attempts: job.attempts,
              error: job.last_error&.slice(0, 500)
            }
          )
        rescue StandardError => e
          BrainzLab.debug_log("Delayed::Job error recording failed: #{e.message}")
        end

        def record_failure(job)
          BrainzLab::Reflex.add_breadcrumb(
            "DelayedJob failed permanently: #{extract_job_name(job)}",
            category: "job.delayed_job.failure",
            level: :error,
            data: {
              job_id: job.id,
              attempts: job.attempts,
              error: job.last_error&.slice(0, 500)
            }
          )
        rescue StandardError => e
          BrainzLab.debug_log("Delayed::Job failure recording failed: #{e.message}")
        end

        def extract_job_name(job)
          payload = job.payload_object
          case payload
          when ::Delayed::PerformableMethod
            "#{payload.object.class}##{payload.method_name}"
          when ::Delayed::PerformableMailer
            "#{payload.object}##{payload.method_name}"
          else
            payload.class.name
          end
        rescue StandardError
          job.name || "Unknown"
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

      # Delayed::Job Plugin (alternative installation method)
      class Plugin < ::Delayed::Plugin
        callbacks do |lifecycle|
          lifecycle.around(:invoke_job) do |job, *args, &block|
            DelayedJobInstrumentation.send(:around_invoke, job, &block)
          end

          lifecycle.after(:error) do |worker, job|
            DelayedJobInstrumentation.send(:record_error, job)
          end

          lifecycle.after(:failure) do |worker, job|
            DelayedJobInstrumentation.send(:record_failure, job)
          end
        end
      end if defined?(::Delayed::Plugin)
    end
  end
end
