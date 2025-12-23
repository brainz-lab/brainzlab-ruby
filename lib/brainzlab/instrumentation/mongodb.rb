# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module MongoDBInstrumentation
      @installed = false

      class << self
        def install!
          return if @installed

          installed_any = false

          # Install MongoDB Ruby Driver monitoring
          if defined?(::Mongo::Client)
            install_mongo_driver!
            installed_any = true
          end

          # Install Mongoid APM subscriber
          if defined?(::Mongoid)
            install_mongoid!
            installed_any = true
          end

          return unless installed_any

          @installed = true
          BrainzLab.debug_log("MongoDB instrumentation installed")
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end

        private

        def install_mongo_driver!
          # Subscribe to command monitoring events
          subscriber = CommandSubscriber.new

          ::Mongo::Monitoring::Global.subscribe(
            ::Mongo::Monitoring::COMMAND,
            subscriber
          )
        end

        def install_mongoid!
          # For Mongoid 7+, use the APM module
          if ::Mongoid.respond_to?(:subscribe)
            ::Mongoid.subscribe(CommandSubscriber.new)
          end
        end
      end

      # MongoDB Command Subscriber
      class CommandSubscriber
        SKIP_COMMANDS = %w[isMaster ismaster buildInfo getLastError saslStart saslContinue].freeze

        def initialize
          @commands = {}
        end

        # Called when command starts
        def started(event)
          return if skip_command?(event.command_name)

          @commands[event.request_id] = {
            started_at: Time.now.utc,
            command_name: event.command_name,
            database: event.database_name,
            collection: extract_collection(event)
          }
        end

        # Called when command succeeds
        def succeeded(event)
          record_command(event, success: true)
        end

        # Called when command fails
        def failed(event)
          record_command(event, success: false, error: event.message)
        end

        private

        def skip_command?(command_name)
          SKIP_COMMANDS.include?(command_name.to_s)
        end

        def extract_collection(event)
          # Try to extract collection name from command
          cmd = event.command
          cmd["collection"] || cmd[event.command_name] || cmd.keys.first
        rescue StandardError
          nil
        end

        def record_command(event, success:, error: nil)
          command_data = @commands.delete(event.request_id)
          return unless command_data

          duration_ms = event.duration * 1000 # Convert seconds to ms
          command_name = command_data[:command_name]
          collection = command_data[:collection]
          database = command_data[:database]

          level = success ? :info : :error

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "MongoDB #{command_name}",
              category: "mongodb",
              level: level,
              data: {
                command: command_name,
                collection: collection,
                database: database,
                duration_ms: duration_ms.round(2),
                error: error
              }.compact
            )
          end

          # Record span for Pulse
          record_span(
            command_name: command_name,
            collection: collection,
            database: database,
            started_at: command_data[:started_at],
            duration_ms: duration_ms,
            success: success,
            error: error
          )

          # Log to Recall
          if BrainzLab.configuration.recall_enabled
            log_method = success ? :debug : :warn
            BrainzLab::Recall.send(
              log_method,
              "MongoDB #{command_name} #{collection} (#{duration_ms.round(2)}ms)",
              command: command_name,
              collection: collection,
              database: database,
              duration_ms: duration_ms.round(2),
              error: error
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("MongoDB command recording failed: #{e.message}")
        end

        def record_span(command_name:, collection:, database:, started_at:, duration_ms:, success:, error:)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          span = {
            span_id: SecureRandom.uuid,
            name: "MongoDB #{command_name} #{collection}".strip,
            kind: "mongodb",
            started_at: started_at,
            ended_at: Time.now.utc,
            duration_ms: duration_ms.round(2),
            data: {
              command: command_name,
              collection: collection,
              database: database
            }.compact
          }

          unless success
            span[:error] = true
            span[:error_message] = error
          end

          spans << span
        end
      end
    end
  end
end
