# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module DalliInstrumentation
      TRACKED_COMMANDS = %w[get set add replace delete incr decr cas get_multi set_multi].freeze

      class << self
        def install!
          return unless defined?(::Dalli::Client)

          install_client_instrumentation!

          BrainzLab.debug_log('[Instrumentation] Dalli/Memcached instrumentation installed')
        end

        private

        def install_client_instrumentation!
          ::Dalli::Client.class_eval do
            TRACKED_COMMANDS.each do |cmd|
              original_method = "original_#{cmd}"
              next if method_defined?(original_method)

              alias_method original_method, cmd

              define_method(cmd) do |*args, &block|
                BrainzLab::Instrumentation::DalliInstrumentation.track_command(cmd, args) do
                  send(original_method, *args, &block)
                end
              end
            end
          end
        end
      end

      def self.track_command(command, args)
        started_at = Time.now

        begin
          result = yield
          track_success(command, args, started_at, result)
          result
        rescue StandardError => e
          track_error(command, args, started_at, e)
          raise
        end
      end

      def self.track_success(command, args, started_at, result)
        duration_ms = ((Time.now - started_at) * 1000).round(2)
        key = extract_key(args)

        # Add breadcrumb
        BrainzLab::Reflex.add_breadcrumb(
          "Memcached #{command.upcase}",
          category: 'cache',
          level: :info,
          data: { command: command, key: key, duration_ms: duration_ms }
        )

        # Track with Flux
        return unless BrainzLab.configuration.flux_effectively_enabled?

        tags = { command: command }
        BrainzLab::Flux.distribution('memcached.duration_ms', duration_ms, tags: tags)
        BrainzLab::Flux.increment('memcached.commands', tags: tags)

        # Track cache hits/misses for get commands
        return unless command == 'get'

        if result.nil?
          BrainzLab::Flux.increment('memcached.miss', tags: tags)
        else
          BrainzLab::Flux.increment('memcached.hit', tags: tags)
        end
      end

      def self.track_error(command, args, started_at, error)
        ((Time.now - started_at) * 1000).round(2)
        key = extract_key(args)

        BrainzLab::Reflex.add_breadcrumb(
          "Memcached #{command.upcase} failed: #{error.message}",
          category: 'cache',
          level: :error,
          data: { command: command, key: key, error: error.class.name }
        )

        return unless BrainzLab.configuration.flux_effectively_enabled?

        BrainzLab::Flux.increment('memcached.errors', tags: { command: command })
      end

      def self.extract_key(args)
        key = args.first
        case key
        when String
          key.length > 50 ? "#{key[0..47]}..." : key
        when Array
          "[#{key.size} keys]"
        else
          key.to_s[0..50]
        end
      end
    end
  end
end
