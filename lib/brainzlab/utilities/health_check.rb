# frozen_string_literal: true

module BrainzLab
  module Utilities
    # Health check utility for application health endpoints
    # Provides checks for database, cache, queues, and external services
    #
    # @example Basic usage in Rails routes
    #   # config/routes.rb
    #   mount BrainzLab::Utilities::HealthCheck::Engine => "/health"
    #
    # @example Manual usage
    #   result = BrainzLab::Utilities::HealthCheck.run
    #   result[:status]  # => "healthy" or "unhealthy"
    #   result[:checks]  # => { database: { status: "ok", latency_ms: 5 }, ... }
    #
    class HealthCheck
      CHECKS = %i[database redis cache queue memory disk].freeze

      class << self
        # Run all configured health checks
        def run(checks: nil)
          checks_to_run = checks || CHECKS
          results = {}
          overall_healthy = true

          checks_to_run.each do |check|
            begin
              result = send("check_#{check}")
              results[check] = result
              overall_healthy = false if result[:status] != "ok"
            rescue StandardError => e
              results[check] = { status: "error", message: e.message }
              overall_healthy = false
            end
          end

          {
            status: overall_healthy ? "healthy" : "unhealthy",
            timestamp: Time.now.utc.iso8601,
            checks: results
          }
        end

        # Quick check - just returns status
        def healthy?
          result = run
          result[:status] == "healthy"
        end

        # Database connectivity check
        def check_database
          return { status: "skip", message: "ActiveRecord not loaded" } unless defined?(ActiveRecord::Base)

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          ActiveRecord::Base.connection.execute("SELECT 1")
          latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)

          { status: "ok", latency_ms: latency }
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        # Redis connectivity check
        def check_redis
          return { status: "skip", message: "Redis not configured" } unless defined?(Redis)

          redis = find_redis_connection
          return { status: "skip", message: "No Redis connection found" } unless redis

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          redis.ping
          latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)

          { status: "ok", latency_ms: latency }
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        # Rails cache check
        def check_cache
          return { status: "skip", message: "Rails not loaded" } unless defined?(Rails)

          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          key = "brainzlab_health_check_#{SecureRandom.hex(4)}"
          Rails.cache.write(key, "ok", expires_in: 10.seconds)
          value = Rails.cache.read(key)
          Rails.cache.delete(key)
          latency = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(2)

          if value == "ok"
            { status: "ok", latency_ms: latency }
          else
            { status: "error", message: "Cache read/write failed" }
          end
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        # Queue system check
        def check_queue
          if defined?(SolidQueue)
            check_solid_queue
          elsif defined?(Sidekiq)
            check_sidekiq
          elsif defined?(GoodJob)
            check_good_job
          else
            { status: "skip", message: "No queue system detected" }
          end
        end

        # Memory usage check
        def check_memory
          mem_info = memory_usage

          status = if mem_info[:percentage] > 90
                     "warning"
                   elsif mem_info[:percentage] > 95
                     "error"
                   else
                     "ok"
                   end

          {
            status: status,
            used_mb: mem_info[:used_mb],
            percentage: mem_info[:percentage]
          }
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        # Disk space check
        def check_disk
          disk_info = disk_usage

          status = if disk_info[:percentage] > 90
                     "warning"
                   elsif disk_info[:percentage] > 95
                     "error"
                   else
                     "ok"
                   end

          {
            status: status,
            used_gb: disk_info[:used_gb],
            available_gb: disk_info[:available_gb],
            percentage: disk_info[:percentage]
          }
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        # Register a custom health check
        def register(name, &block)
          custom_checks[name.to_sym] = block
        end

        def custom_checks
          @custom_checks ||= {}
        end

        private

        def find_redis_connection
          # Try common Redis connection sources
          if defined?(Redis.current) && Redis.current
            Redis.current
          elsif defined?(Sidekiq) && Sidekiq.respond_to?(:redis)
            Sidekiq.redis { |conn| return conn }
          elsif defined?(Rails) && Rails.application.config.respond_to?(:redis)
            Rails.application.config.redis
          end
        rescue StandardError
          nil
        end

        def check_solid_queue
          return { status: "skip", message: "SolidQueue not loaded" } unless defined?(SolidQueue)

          # Check if processes are running
          if defined?(SolidQueue::Process)
            process_count = SolidQueue::Process.where("last_heartbeat_at > ?", 5.minutes.ago).count
            {
              status: process_count > 0 ? "ok" : "warning",
              processes: process_count
            }
          else
            { status: "ok", message: "SolidQueue configured" }
          end
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        def check_sidekiq
          return { status: "skip", message: "Sidekiq not loaded" } unless defined?(Sidekiq)

          stats = Sidekiq::Stats.new
          {
            status: "ok",
            processed: stats.processed,
            failed: stats.failed,
            queues: stats.queues,
            workers: stats.workers_size
          }
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        def check_good_job
          return { status: "skip", message: "GoodJob not loaded" } unless defined?(GoodJob)

          {
            status: "ok",
            pending: GoodJob::Job.where(performed_at: nil).count,
            running: GoodJob::Job.running.count
          }
        rescue StandardError => e
          { status: "error", message: e.message }
        end

        def memory_usage
          # Use /proc/self/status on Linux, ps on macOS
          if File.exist?("/proc/self/status")
            status = File.read("/proc/self/status")
            vm_rss = status.match(/VmRSS:\s+(\d+)\s+kB/)&.captures&.first&.to_i || 0
            used_mb = (vm_rss / 1024.0).round(2)
          else
            # macOS fallback
            pid = Process.pid
            output = `ps -o rss= -p #{pid}`.strip
            used_mb = (output.to_i / 1024.0).round(2)
          end

          # Estimate percentage (based on typical container memory)
          max_mb = ENV.fetch("MEMORY_LIMIT_MB", 512).to_i
          percentage = ((used_mb / max_mb) * 100).round(2)

          { used_mb: used_mb, percentage: percentage }
        end

        def disk_usage
          output = `df -k /`.split("\n").last.split
          total = output[1].to_i / 1024 / 1024.0
          used = output[2].to_i / 1024 / 1024.0
          available = output[3].to_i / 1024 / 1024.0
          percentage = ((used / total) * 100).round(2)

          {
            used_gb: used.round(2),
            available_gb: available.round(2),
            percentage: percentage
          }
        end
      end

      # Rails Engine for mounting health endpoints
      if defined?(::Rails::Engine)
        class Engine < ::Rails::Engine
          isolate_namespace BrainzLab::Utilities::HealthCheck

          routes.draw do
            get "/", to: "health#show"
            get "/live", to: "health#live"
            get "/ready", to: "health#ready"
          end
        end
      end

      # Controller for health endpoints
      if defined?(ActionController::API)
        class HealthController < ActionController::API
          def show
            result = HealthCheck.run
            status = result[:status] == "healthy" ? :ok : :service_unavailable
            render json: result, status: status
          end

          def live
            # Liveness probe - just check if the app is running
            render json: { status: "ok", timestamp: Time.now.utc.iso8601 }
          end

          def ready
            # Readiness probe - check critical dependencies
            result = HealthCheck.run(checks: [:database, :redis])
            status = result[:status] == "healthy" ? :ok : :service_unavailable
            render json: result, status: status
          end
        end
      end
    end
  end
end
