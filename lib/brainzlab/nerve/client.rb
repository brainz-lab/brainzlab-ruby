# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module BrainzLab
  module Nerve
    class Client
      def initialize(config)
        @config = config
        @base_url = config.nerve_url || 'https://nerve.brainzlab.ai'
      end

      # Report a job execution
      def report_job(job_class:, job_id:, queue:, status:, started_at:, ended_at:, **attributes)
        response = request(
          :post,
          '/api/v1/jobs',
          body: {
            job_class: job_class,
            job_id: job_id,
            queue: queue,
            status: status,
            started_at: started_at.iso8601(3),
            ended_at: ended_at.iso8601(3),
            duration_ms: ((ended_at - started_at) * 1000).round(2),
            **attributes
          }
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error('report_job', e)
        false
      end

      # Report a job failure
      def report_failure(job_class:, job_id:, queue:, error_class:, error_message:, backtrace: nil, **attributes)
        response = request(
          :post,
          '/api/v1/jobs/failures',
          body: {
            job_class: job_class,
            job_id: job_id,
            queue: queue,
            error_class: error_class,
            error_message: error_message,
            backtrace: backtrace&.first(20),
            failed_at: Time.now.utc.iso8601(3),
            **attributes
          }
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error('report_failure', e)
        false
      end

      # Get job statistics
      def stats(queue: nil, job_class: nil, period: '1h')
        params = { period: period }
        params[:queue] = queue if queue
        params[:job_class] = job_class if job_class

        response = request(:get, '/api/v1/stats', params: params)

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error('stats', e)
        nil
      end

      # List recent jobs
      def list_jobs(queue: nil, status: nil, limit: 100)
        params = { limit: limit }
        params[:queue] = queue if queue
        params[:status] = status if status

        response = request(:get, '/api/v1/jobs', params: params)

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:jobs] || []
      rescue StandardError => e
        log_error('list_jobs', e)
        []
      end

      # List queues
      def list_queues
        response = request(:get, '/api/v1/queues')

        return [] unless response.is_a?(Net::HTTPSuccess)

        data = JSON.parse(response.body, symbolize_names: true)
        data[:queues] || []
      rescue StandardError => e
        log_error('list_queues', e)
        []
      end

      # Get queue details
      def get_queue(name)
        response = request(:get, "/api/v1/queues/#{CGI.escape(name)}")

        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body, symbolize_names: true)
      rescue StandardError => e
        log_error('get_queue', e)
        nil
      end

      # Retry a failed job
      def retry_job(job_id)
        response = request(:post, "/api/v1/jobs/#{job_id}/retry")
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        log_error('retry_job', e)
        false
      end

      # Delete a job
      def delete_job(job_id)
        response = request(:delete, "/api/v1/jobs/#{job_id}")
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNoContent)
      rescue StandardError => e
        log_error('delete_job', e)
        false
      end

      # Report queue metrics
      def report_metrics(queue:, size:, latency_ms: nil, workers: nil)
        response = request(
          :post,
          '/api/v1/metrics',
          body: {
            queue: queue,
            size: size,
            latency_ms: latency_ms,
            workers: workers,
            timestamp: Time.now.utc.iso8601(3)
          }
        )

        response.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        log_error('report_metrics', e)
        false
      end

      def provision(project_id:, app_name:)
        response = request(
          :post,
          '/api/v1/projects/provision',
          body: { project_id: project_id, app_name: app_name },
          use_service_key: true
        )

        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPCreated)
      rescue StandardError => e
        log_error('provision', e)
        false
      end

      private

      def request(method, path, headers: {}, body: nil, params: nil, use_service_key: false)
        uri = URI.parse("#{@base_url}#{path}")

        uri.query = URI.encode_www_form(params) if params

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = 5
        http.read_timeout = 10

        request = case method
                  when :get
                    Net::HTTP::Get.new(uri)
                  when :post
                    Net::HTTP::Post.new(uri)
                  when :put
                    Net::HTTP::Put.new(uri)
                  when :delete
                    Net::HTTP::Delete.new(uri)
                  end

        request['Content-Type'] = 'application/json'
        request['Accept'] = 'application/json'

        if use_service_key
          request['X-Service-Key'] = @config.nerve_master_key || @config.secret_key
        else
          auth_key = @config.nerve_api_key || @config.secret_key
          request['Authorization'] = "Bearer #{auth_key}" if auth_key
        end

        headers.each { |k, v| request[k] = v }
        request.body = body.to_json if body

        http.request(request)
      end

      def log_error(operation, error)
        BrainzLab.debug_log("[Nerve::Client] #{operation} failed: #{error.message}")
      end
    end
  end
end
