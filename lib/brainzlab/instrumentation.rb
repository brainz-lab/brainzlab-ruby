# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    class << self
      def install!
        config = BrainzLab.configuration

        # HTTP client instrumentation
        if config.instrument_http
          install_net_http!
          install_faraday!
          install_httparty!
        end

        # Database instrumentation (breadcrumbs for Reflex)
        install_active_record! if config.instrument_active_record

        # Redis instrumentation
        install_redis! if config.instrument_redis

        # Background job instrumentation
        install_sidekiq! if config.instrument_sidekiq

        # GraphQL instrumentation
        install_graphql! if config.instrument_graphql

        # MongoDB instrumentation
        install_mongodb! if config.instrument_mongodb

        # Elasticsearch instrumentation
        install_elasticsearch! if config.instrument_elasticsearch

        # ActionMailer instrumentation
        install_action_mailer! if config.instrument_action_mailer

        # Delayed::Job instrumentation
        install_delayed_job! if config.instrument_delayed_job

        # Grape API instrumentation
        install_grape! if config.instrument_grape
      end

      def install_net_http!
        require_relative "instrumentation/net_http"
        NetHttp.install!
      end

      def install_faraday!
        return unless defined?(::Faraday)

        require_relative "instrumentation/faraday"
        FaradayMiddleware.install!
      end

      def install_httparty!
        return unless defined?(::HTTParty)

        require_relative "instrumentation/httparty"
        HTTPartyInstrumentation.install!
      end

      def install_active_record!
        require_relative "instrumentation/active_record"
        ActiveRecord.install!
      end

      def install_redis!
        return unless defined?(::Redis)

        require_relative "instrumentation/redis"
        RedisInstrumentation.install!
      end

      def install_sidekiq!
        return unless defined?(::Sidekiq)

        require_relative "instrumentation/sidekiq"
        SidekiqInstrumentation.install!
      end

      def install_graphql!
        return unless defined?(::GraphQL)

        require_relative "instrumentation/graphql"
        GraphQLInstrumentation.install!
      end

      def install_mongodb!
        return unless defined?(::Mongo) || defined?(::Mongoid)

        require_relative "instrumentation/mongodb"
        MongoDBInstrumentation.install!
      end

      def install_elasticsearch!
        return unless defined?(::Elasticsearch) || defined?(::OpenSearch)

        require_relative "instrumentation/elasticsearch"
        ElasticsearchInstrumentation.install!
      end

      def install_action_mailer!
        return unless defined?(::ActionMailer)

        require_relative "instrumentation/action_mailer"
        ActionMailerInstrumentation.install!
      end

      def install_delayed_job!
        return unless defined?(::Delayed::Job) || defined?(::Delayed::Backend)

        require_relative "instrumentation/delayed_job"
        DelayedJobInstrumentation.install!
      end

      def install_grape!
        return unless defined?(::Grape::API)

        require_relative "instrumentation/grape"
        GrapeInstrumentation.install!
      end

      # Manual installation methods for lazy-loaded libraries
      def install_http!
        install_net_http!
        install_faraday!
        install_httparty!
      end
    end
  end
end
