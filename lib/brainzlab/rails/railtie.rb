# frozen_string_literal: true

module BrainzLab
  module Rails
    class Railtie < ::Rails::Railtie
      generators do
        require "generators/brainzlab/install/install_generator"
      end

      initializer "brainzlab.configure_rails_initialization" do |app|
        # Set defaults from Rails
        BrainzLab.configure do |config|
          config.environment ||= ::Rails.env.to_s
          config.service ||= begin
            ::Rails.application.class.module_parent_name.underscore
          rescue StandardError
            nil
          end
        end

        # Add request context middleware (runs early)
        app.middleware.insert_after ActionDispatch::RequestId, BrainzLab::Rails::Middleware
      end

      config.after_initialize do
        # Set up custom log formatter
        setup_log_formatter if BrainzLab.configuration.log_formatter_enabled

        # Install instrumentation (HTTP tracking, etc.)
        BrainzLab::Instrumentation.install!

        # Hook into Rails 7+ error reporting
        if defined?(::Rails.error) && ::Rails.error.respond_to?(:subscribe)
          ::Rails.error.subscribe(BrainzLab::Rails::ErrorSubscriber.new)
        end

        # Hook into ActiveJob
        if defined?(ActiveJob::Base)
          ActiveJob::Base.include(BrainzLab::Rails::ActiveJobExtension)
        end

        # Hook into ActionController for rescue_from fallback
        if defined?(ActionController::Base)
          ActionController::Base.include(BrainzLab::Rails::ControllerExtension)
        end

        # Hook into Sidekiq if available
        if defined?(Sidekiq)
          Sidekiq.configure_server do |config|
            config.error_handlers << BrainzLab::Rails::SidekiqErrorHandler.new
          end
        end
      end

      class << self
        def setup_log_formatter
          # Lazy require to ensure Rails is fully loaded
          require_relative "log_formatter"
          require_relative "log_subscriber"

          config = BrainzLab.configuration

          formatter_config = {
            enabled: config.log_formatter_enabled,
            colors: config.log_formatter_colors.nil? ? $stdout.tty? : config.log_formatter_colors,
            hide_assets: config.log_formatter_hide_assets,
            compact_assets: config.log_formatter_compact_assets,
            show_params: config.log_formatter_show_params
          }

          # Create formatter and attach to subscriber
          formatter = LogFormatter.new(formatter_config)
          LogSubscriber.formatter = formatter

          # Attach our subscribers
          LogSubscriber.attach_to :action_controller
          SqlLogSubscriber.attach_to :active_record
          ViewLogSubscriber.attach_to :action_view
          CableLogSubscriber.attach_to :action_cable

          # Silence Rails default ActionController logging
          silence_rails_logging
        end

        def silence_rails_logging
          # Create a null logger that discards all output
          null_logger = Logger.new(File::NULL)
          null_logger.level = Logger::FATAL

          # Silence ActiveRecord SQL logging
          if defined?(ActiveRecord::Base)
            ActiveRecord::Base.logger = null_logger
          end

          # Silence ActionController logging (the "Completed" message)
          if defined?(ActionController::Base)
            ActionController::Base.logger = null_logger
          end

          # Silence ActionView logging
          if defined?(ActionView::Base)
            ActionView::Base.logger = null_logger
          end

          # Silence the class-level loggers for specific subscribers
          if defined?(ActionController::LogSubscriber)
            ActionController::LogSubscriber.logger = null_logger
          end

          if defined?(ActionView::LogSubscriber)
            ActionView::LogSubscriber.logger = null_logger
          end

          if defined?(ActiveRecord::LogSubscriber)
            ActiveRecord::LogSubscriber.logger = null_logger
          end

          # Silence ActionCable logging
          if defined?(ActionCable::Server::Base)
            ActionCable.server.config.logger = null_logger
          end

          if defined?(ActionCable::Connection::TaggedLoggerProxy)
            # ActionCable uses a tagged logger proxy that we need to quiet
          end

          # Silence the main Rails logger to remove "Started GET" messages
          # Wrap the formatter to filter specific messages
          if defined?(::Rails.logger) && ::Rails.logger.respond_to?(:formatter=)
            original_formatter = ::Rails.logger.formatter || Logger::Formatter.new
            ::Rails.logger.formatter = FilteringFormatter.new(original_formatter)
          end
        rescue StandardError
          # Silently fail if we can't silence
        end
      end
    end

    # Filtering formatter that suppresses request-related messages
    # Uses SimpleDelegator to support all formatter methods (including tagged logging)
    class FilteringFormatter < SimpleDelegator
      FILTERED_PATTERNS = [
        /^Started (GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)/,
        /^Processing by/,
        /^Completed \d+/,
        /^Cannot render console from/,
        /^Parameters:/,
        /^Rendering/,
        /^Rendered/,
        /^\[ActionCable\] Broadcasting/,
        /^\s*$/  # Empty lines
      ].freeze

      def call(severity, datetime, progname, msg)
        return nil if should_filter?(msg)

        __getobj__.call(severity, datetime, progname, msg)
      end

      private

      def should_filter?(msg)
        return false unless msg

        msg_str = msg.to_s
        FILTERED_PATTERNS.any? { |pattern| msg_str =~ pattern }
      end
    end

    # Middleware for request context
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        request = ActionDispatch::Request.new(env)

        # Set request context
        context = BrainzLab::Context.current
        request_id = request.request_id || env["action_dispatch.request_id"]
        context.request_id = request_id

        # Store request_id in thread local for log subscriber
        Thread.current[:brainzlab_request_id] = request_id

        # Capture session_id - access session to ensure it's loaded
        if request.session.respond_to?(:id)
          # Force session load by accessing it
          session_id = request.session.id rescue nil
          context.session_id = session_id.to_s if session_id.present?
        end

        # Capture full request info for Reflex
        context.request_method = request.request_method
        context.request_path = request.path
        context.request_url = request.url
        context.request_params = filter_params(request.params.to_h)
        context.request_headers = extract_headers(env)

        # Add breadcrumb for request start
        BrainzLab::Reflex.add_breadcrumb(
          "#{request.request_method} #{request.path}",
          category: "http.request",
          level: :info,
          data: { url: request.url }
        )

        # Add request data to Recall context
        context.set_context(
          path: request.path,
          method: request.request_method,
          ip: request.remote_ip,
          user_agent: request.user_agent
        )

        status, headers, response = @app.call(env)

        # Add breadcrumb for response
        BrainzLab::Reflex.add_breadcrumb(
          "Response #{status}",
          category: "http.response",
          level: status >= 400 ? :error : :info,
          data: { status: status }
        )

        [status, headers, response]
      ensure
        Thread.current[:brainzlab_request_id] = nil
        BrainzLab::Context.clear!
      end

      private

      def filter_params(params)
        filtered = params.dup
        BrainzLab::Reflex::FILTERED_PARAMS.each do |key|
          filtered.delete(key)
          filtered.delete(key.to_sym)
        end
        # Also filter nested password fields
        deep_filter(filtered)
      end

      def deep_filter(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), h|
            if BrainzLab::Reflex::FILTERED_PARAMS.include?(k.to_s)
              h[k] = "[FILTERED]"
            else
              h[k] = deep_filter(v)
            end
          end
        when Array
          obj.map { |v| deep_filter(v) }
        else
          obj
        end
      end

      def extract_headers(env)
        headers = {}
        env.each do |key, value|
          next unless key.start_with?("HTTP_")
          next if key == "HTTP_COOKIE"
          next if key == "HTTP_AUTHORIZATION"

          header_name = key.sub("HTTP_", "").split("_").map(&:capitalize).join("-")
          headers[header_name] = value
        end
        headers
      end
    end

    # Rails 7+ ErrorReporter subscriber
    class ErrorSubscriber
      def report(error, handled:, severity:, context: {}, source: nil)
        # Capture both handled and unhandled, but mark them
        BrainzLab::Reflex.capture(error,
          handled: handled,
          severity: severity.to_s,
          source: source,
          extra: context
        )
      rescue StandardError => e
        BrainzLab.configuration.logger&.error("[BrainzLab] ErrorSubscriber failed: #{e.message}")
      end
    end

    # ActionController extension for error capture
    module ControllerExtension
      extend ActiveSupport::Concern

      included do
        around_action :brainzlab_capture_context
        rescue_from Exception, with: :brainzlab_capture_exception
      end

      private

      def brainzlab_capture_context
        # Set controller/action context
        context = BrainzLab::Context.current
        context.controller = self.class.name
        context.action = action_name

        # Add breadcrumb
        BrainzLab::Reflex.add_breadcrumb(
          "#{self.class.name}##{action_name}",
          category: "controller",
          level: :info
        )

        yield
      end

      def brainzlab_capture_exception(exception)
        BrainzLab::Reflex.capture(exception)
        raise exception # Re-raise to let Rails handle it
      end
    end

    # ActiveJob extension for background job error capture
    module ActiveJobExtension
      extend ActiveSupport::Concern

      included do
        around_perform :brainzlab_around_perform
        rescue_from Exception, with: :brainzlab_rescue_job
      end

      private

      def brainzlab_around_perform
        BrainzLab::Context.current.set_context(
          job_class: self.class.name,
          job_id: job_id,
          queue_name: queue_name,
          arguments: arguments.map(&:to_s).first(5) # Limit for safety
        )

        BrainzLab::Reflex.add_breadcrumb(
          "Job #{self.class.name}",
          category: "job",
          level: :info,
          data: { job_id: job_id, queue: queue_name }
        )

        yield
      ensure
        BrainzLab::Context.clear!
      end

      def brainzlab_rescue_job(exception)
        BrainzLab::Reflex.capture(exception,
          tags: { type: "background_job" },
          extra: {
            job_class: self.class.name,
            job_id: job_id,
            queue_name: queue_name,
            executions: executions,
            arguments: arguments.map(&:to_s).first(5)
          }
        )
        raise exception # Re-raise to let ActiveJob handle retries
      end
    end

    # Sidekiq error handler
    class SidekiqErrorHandler
      def call(exception, context)
        BrainzLab::Reflex.capture(exception,
          tags: { type: "sidekiq" },
          extra: {
            job_class: context[:job]["class"],
            job_id: context[:job]["jid"],
            queue: context[:job]["queue"],
            args: context[:job]["args"]&.map(&:to_s)&.first(5),
            retry_count: context[:job]["retry_count"]
          }
        )
      rescue StandardError => e
        BrainzLab.configuration.logger&.error("[BrainzLab] Sidekiq handler failed: #{e.message}")
      end
    end
  end
end
