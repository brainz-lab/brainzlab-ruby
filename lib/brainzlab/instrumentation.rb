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

        # Modern job queue instrumentation
        install_solid_queue! if config.instrument_solid_queue
        install_good_job! if config.instrument_good_job
        install_resque! if config.instrument_resque

        # Additional HTTP clients
        install_excon! if config.instrument_excon
        install_typhoeus! if config.instrument_typhoeus

        # Caching
        install_dalli! if config.instrument_dalli

        # Cloud & Payment
        install_aws! if config.instrument_aws
        install_stripe! if config.instrument_stripe
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

      def install_solid_queue!
        return unless defined?(::SolidQueue)

        require_relative "instrumentation/solid_queue"
        SolidQueueInstrumentation.install!
      end

      def install_good_job!
        return unless defined?(::GoodJob)

        require_relative "instrumentation/good_job"
        GoodJobInstrumentation.install!
      end

      def install_resque!
        return unless defined?(::Resque)

        require_relative "instrumentation/resque"
        ResqueInstrumentation.install!
      end

      def install_excon!
        return unless defined?(::Excon)

        require_relative "instrumentation/excon"
        ExconInstrumentation.install!
      end

      def install_typhoeus!
        return unless defined?(::Typhoeus)

        require_relative "instrumentation/typhoeus"
        TyphoeusInstrumentation.install!
      end

      def install_dalli!
        return unless defined?(::Dalli::Client)

        require_relative "instrumentation/dalli"
        DalliInstrumentation.install!
      end

      def install_aws!
        return unless defined?(::Aws)

        require_relative "instrumentation/aws"
        AWSInstrumentation.install!
      end

      def install_stripe!
        return unless defined?(::Stripe)

        require_relative "instrumentation/stripe"
        StripeInstrumentation.install!
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
