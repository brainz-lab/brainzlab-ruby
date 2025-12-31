# frozen_string_literal: true

require_relative 'nerve/client'
require_relative 'nerve/provisioner'

module BrainzLab
  module Nerve
    class << self
      # Report a completed job
      # @param job_class [String] Job class name
      # @param job_id [String] Job ID
      # @param queue [String] Queue name
      # @param started_at [Time] When job started
      # @param ended_at [Time] When job ended (defaults to now)
      # @param attributes [Hash] Additional attributes
      #
      # @example
      #   BrainzLab::Nerve.report_success(
      #     job_class: "ProcessOrderJob",
      #     job_id: "abc-123",
      #     queue: "default",
      #     started_at: 1.minute.ago
      #   )
      #
      def report_success(job_class:, job_id:, queue:, started_at:, ended_at: Time.now, **attributes)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.nerve_valid?

        client.report_job(
          job_class: job_class,
          job_id: job_id,
          queue: queue,
          status: 'completed',
          started_at: started_at,
          ended_at: ended_at,
          **attributes
        )
      end

      # Report a failed job
      def report_failure(job_class:, job_id:, queue:, error:, started_at: nil, **attributes)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.nerve_valid?

        client.report_failure(
          job_class: job_class,
          job_id: job_id,
          queue: queue,
          error_class: error.class.name,
          error_message: error.message,
          backtrace: error.backtrace,
          started_at: started_at,
          **attributes
        )
      end

      # Report a job that's currently running
      def report_started(job_class:, job_id:, queue:, **attributes)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.nerve_valid?

        client.report_job(
          job_class: job_class,
          job_id: job_id,
          queue: queue,
          status: 'running',
          started_at: Time.now,
          ended_at: Time.now,
          **attributes
        )
      end

      # Get job statistics
      # @param queue [String] Filter by queue (optional)
      # @param job_class [String] Filter by job class (optional)
      # @param period [String] Time period: "1h", "24h", "7d", "30d"
      def stats(queue: nil, job_class: nil, period: '1h')
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.nerve_valid?

        client.stats(queue: queue, job_class: job_class, period: period)
      end

      # List recent jobs
      def jobs(queue: nil, status: nil, limit: 100)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.nerve_valid?

        client.list_jobs(queue: queue, status: status, limit: limit)
      end

      # List all queues
      def queues
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.nerve_valid?

        client.list_queues
      end

      # Get queue details
      def queue(name)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.nerve_valid?

        client.get_queue(name)
      end

      # Retry a failed job
      def retry(job_id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.nerve_valid?

        client.retry_job(job_id)
      end

      # Delete a job
      def delete(job_id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.nerve_valid?

        client.delete_job(job_id)
      end

      # Report queue metrics (for custom job backends)
      def report_metrics(queue:, size:, latency_ms: nil, workers: nil)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.nerve_valid?

        client.report_metrics(
          queue: queue,
          size: size,
          latency_ms: latency_ms,
          workers: workers
        )
      end

      # Track a job execution (block helper)
      # @example
      #   BrainzLab::Nerve.track(job_class: "MyJob", job_id: "123", queue: "default") do
      #     # job work
      #   end
      #
      def track(job_class:, job_id:, queue: 'default', **attributes)
        started_at = Time.now

        begin
          result = yield
          report_success(
            job_class: job_class,
            job_id: job_id,
            queue: queue,
            started_at: started_at,
            **attributes
          )
          result
        rescue StandardError => e
          report_failure(
            job_class: job_class,
            job_id: job_id,
            queue: queue,
            error: e,
            started_at: started_at,
            **attributes
          )
          raise
        end
      end

      # === INTERNAL ===

      def ensure_provisioned!
        return if @provisioned

        @provisioned = true
        provisioner.ensure_project!
      end

      def provisioner
        @provisioner ||= Provisioner.new(BrainzLab.configuration)
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def reset!
        @client = nil
        @provisioner = nil
        @provisioned = false
      end

      private

      def enabled?
        BrainzLab.configuration.nerve_enabled
      end
    end
  end
end
