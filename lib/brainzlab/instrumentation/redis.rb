# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module RedisInstrumentation
      @installed = false

      class << self
        def install!
          return unless defined?(::Redis)
          return if @installed

          # Redis 5+ uses middleware, older versions need patching
          if redis_5_or_newer?
            install_middleware!
          else
            install_patch!
          end

          @installed = true
          BrainzLab.debug_log('Redis instrumentation installed')
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end

        private

        def redis_5_or_newer?
          defined?(::Redis::VERSION) && Gem::Version.new(::Redis::VERSION) >= Gem::Version.new('5.0')
        end

        def install_middleware!
          # Redis 5+ uses RedisClient with middleware support
          return unless defined?(::RedisClient)

          ::RedisClient.register(Middleware)
        end

        def install_patch!
          # Redis < 5 - patch the client
          ::Redis::Client.prepend(LegacyPatch)
        end
      end

      # Middleware for Redis 5+ (RedisClient)
      module Middleware
        def call(command, redis_config)
          return super unless should_track?

          track_command(command) { super }
        end

        def call_pipelined(commands, redis_config)
          return super unless should_track?

          track_pipeline(commands) { super }
        end

        private

        def should_track?
          BrainzLab.configuration.instrument_redis
        end

        def should_skip_command?(command)
          cmd_name = command.first.to_s.downcase
          ignore = BrainzLab.configuration.redis_ignore_commands || []
          ignore.map(&:downcase).include?(cmd_name)
        end

        def track_command(command)
          return yield if should_skip_command?(command)

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            result = yield
            record_command(command, started_at)
            result
          rescue StandardError => e
            error_info = e.class.name
            record_command(command, started_at, error_info)
            raise
          end
        end

        def track_pipeline(commands)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            result = yield
            record_pipeline(commands, started_at)
            result
          rescue StandardError => e
            error_info = e.class.name
            record_pipeline(commands, started_at, error_info)
            raise
          end
        end

        def record_command(command, started_at, error = nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
          cmd_name = command.first.to_s.upcase
          key = extract_key(command)
          level = error ? :error : :info

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Redis #{cmd_name}",
              category: 'redis',
              level: level,
              data: {
                command: cmd_name,
                key: truncate_key(key),
                duration_ms: duration_ms,
                error: error
              }.compact
            )
          end

          # Record span for Pulse APM
          record_pulse_span(cmd_name, key, duration_ms, error)
        rescue StandardError => e
          BrainzLab.debug_log("Redis instrumentation error: #{e.message}")
        end

        def record_pipeline(commands, started_at, error = nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
          cmd_names = commands.map { |c| c.first.to_s.upcase }.uniq.join(', ')
          level = error ? :error : :info

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Redis PIPELINE (#{commands.size} commands)",
              category: 'redis',
              level: level,
              data: {
                commands: cmd_names,
                count: commands.size,
                duration_ms: duration_ms,
                error: error
              }.compact
            )
          end

          # Record span for Pulse APM
          record_pulse_span('PIPELINE', nil, duration_ms, error, commands.size)
        rescue StandardError => e
          BrainzLab.debug_log("Redis instrumentation error: #{e.message}")
        end

        def record_pulse_span(command, key, duration_ms, error, pipeline_count = nil)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          span = {
            span_id: SecureRandom.uuid,
            name: "Redis #{command}",
            kind: 'redis',
            started_at: Time.now.utc - (duration_ms / 1000.0),
            ended_at: Time.now.utc,
            duration_ms: duration_ms,
            data: {
              command: command,
              key: truncate_key(key),
              pipeline_count: pipeline_count
            }.compact
          }

          if error
            span[:error] = true
            span[:error_class] = error
          end

          spans << span
        end

        def extract_key(command)
          return nil if command.size < 2

          # Most Redis commands have the key as the second argument
          key = command[1]
          key.is_a?(String) ? key : key.to_s
        end

        def truncate_key(key)
          return nil unless key

          key.to_s[0, 100]
        end
      end

      # Patch for Redis < 5
      module LegacyPatch
        def call(command)
          return super unless should_track?
          return super if should_skip_command?(command)

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          begin
            result = super
            record_command(command, started_at)
            result
          rescue StandardError => e
            error_info = e.class.name
            record_command(command, started_at, error_info)
            raise
          end
        end

        def call_pipeline(pipeline)
          return super unless should_track?

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          commands = pipeline.commands

          begin
            result = super
            record_pipeline(commands, started_at)
            result
          rescue StandardError => e
            error_info = e.class.name
            record_pipeline(commands, started_at, error_info)
            raise
          end
        end

        private

        def should_track?
          BrainzLab.configuration.instrument_redis
        end

        def should_skip_command?(command)
          cmd_name = command.first.to_s.downcase
          ignore = BrainzLab.configuration.redis_ignore_commands || []
          ignore.map(&:downcase).include?(cmd_name)
        end

        def record_command(command, started_at, error = nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
          cmd_name = command.first.to_s.upcase
          key = command[1]&.to_s
          level = error ? :error : :info

          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Redis #{cmd_name}",
              category: 'redis',
              level: level,
              data: {
                command: cmd_name,
                key: key&.slice(0, 100),
                duration_ms: duration_ms,
                error: error
              }.compact
            )
          end

          record_pulse_span(cmd_name, key, duration_ms, error)
        rescue StandardError => e
          BrainzLab.debug_log("Redis instrumentation error: #{e.message}")
        end

        def record_pipeline(commands, started_at, error = nil)
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(2)
          level = error ? :error : :info

          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "Redis PIPELINE (#{commands.size} commands)",
              category: 'redis',
              level: level,
              data: {
                count: commands.size,
                duration_ms: duration_ms,
                error: error
              }.compact
            )
          end

          record_pulse_span('PIPELINE', nil, duration_ms, error, commands.size)
        rescue StandardError => e
          BrainzLab.debug_log("Redis instrumentation error: #{e.message}")
        end

        def record_pulse_span(command, key, duration_ms, error, pipeline_count = nil)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          span = {
            span_id: SecureRandom.uuid,
            name: "Redis #{command}",
            kind: 'redis',
            started_at: Time.now.utc - (duration_ms / 1000.0),
            ended_at: Time.now.utc,
            duration_ms: duration_ms,
            data: {
              command: command,
              key: key&.slice(0, 100),
              pipeline_count: pipeline_count
            }.compact
          }

          if error
            span[:error] = true
            span[:error_class] = error
          end

          spans << span
        end
      end
    end
  end
end
