# frozen_string_literal: true

module BrainzLab
  module Instrumentation
    module ElasticsearchInstrumentation
      @installed = false

      class << self
        def install!
          return if @installed

          installed_any = false

          # Elasticsearch gem (elasticsearch-ruby)
          if defined?(::Elasticsearch::Transport::Client)
            install_elasticsearch_transport!
            installed_any = true
          end

          # OpenSearch gem
          if defined?(::OpenSearch::Client)
            install_opensearch!
            installed_any = true
          end

          # Elasticsearch 8.x with new client
          if defined?(::Elastic::Transport::Client)
            install_elastic_transport!
            installed_any = true
          end

          return unless installed_any

          @installed = true
          BrainzLab.debug_log("Elasticsearch instrumentation installed")
        end

        def installed?
          @installed
        end

        def reset!
          @installed = false
        end

        private

        def install_elasticsearch_transport!
          ::Elasticsearch::Transport::Client.prepend(ClientPatch)
        end

        def install_opensearch!
          ::OpenSearch::Client.prepend(ClientPatch)
        end

        def install_elastic_transport!
          ::Elastic::Transport::Client.prepend(ClientPatch)
        end
      end

      # Patch for Elasticsearch/OpenSearch clients
      module ClientPatch
        def perform_request(method, path, params = {}, body = nil, headers = nil)
          return super unless should_track?

          started_at = Time.now.utc
          error_info = nil

          begin
            response = super
            record_request(method, path, params, started_at, response.status)
            response
          rescue StandardError => e
            error_info = e
            record_request(method, path, params, started_at, nil, e)
            raise
          end
        end

        private

        def should_track?
          BrainzLab.configuration.instrument_elasticsearch
        end

        def record_request(method, path, params, started_at, status, error = nil)
          duration_ms = ((Time.now.utc - started_at) * 1000).round(2)
          operation = extract_operation(method, path)
          index = extract_index(path)
          level = error || (status && status >= 400) ? :error : :info

          # Add breadcrumb for Reflex
          if BrainzLab.configuration.reflex_enabled
            BrainzLab::Reflex.add_breadcrumb(
              "ES #{operation}",
              category: "elasticsearch",
              level: level,
              data: {
                method: method.to_s.upcase,
                path: truncate_path(path),
                index: index,
                status: status,
                duration_ms: duration_ms,
                error: error&.class&.name
              }.compact
            )
          end

          # Record span for Pulse
          record_span(
            operation: operation,
            method: method,
            path: path,
            index: index,
            started_at: started_at,
            duration_ms: duration_ms,
            status: status,
            error: error
          )

          # Log to Recall
          if BrainzLab.configuration.recall_enabled
            log_method = error ? :warn : :debug
            BrainzLab::Recall.send(
              log_method,
              "ES #{method.to_s.upcase} #{path} -> #{status || 'ERROR'} (#{duration_ms}ms)",
              method: method.to_s.upcase,
              path: path,
              index: index,
              status: status,
              duration_ms: duration_ms,
              error: error&.message
            )
          end
        rescue StandardError => e
          BrainzLab.debug_log("Elasticsearch recording failed: #{e.message}")
        end

        def record_span(operation:, method:, path:, index:, started_at:, duration_ms:, status:, error:)
          spans = Thread.current[:brainzlab_pulse_spans]
          return unless spans

          span = {
            span_id: SecureRandom.uuid,
            name: "ES #{operation}",
            kind: "elasticsearch",
            started_at: started_at,
            ended_at: Time.now.utc,
            duration_ms: duration_ms,
            data: {
              method: method.to_s.upcase,
              path: truncate_path(path),
              index: index,
              status: status
            }.compact
          }

          if error
            span[:error] = true
            span[:error_class] = error.class.name
            span[:error_message] = error.message&.slice(0, 500)
          end

          spans << span
        end

        def extract_operation(method, path)
          method_str = method.to_s.upcase

          case path
          when %r{/_search} then "search"
          when %r{/_bulk} then "bulk"
          when %r{/_count} then "count"
          when %r{/_mget} then "mget"
          when %r{/_msearch} then "msearch"
          when %r{/_update_by_query} then "update_by_query"
          when %r{/_delete_by_query} then "delete_by_query"
          when %r{/_refresh} then "refresh"
          when %r{/_mapping} then "mapping"
          when %r{/_settings} then "settings"
          when %r{/_alias} then "alias"
          when %r{/_analyze} then "analyze"
          else
            case method_str
            when "GET" then "get"
            when "POST" then "index"
            when "PUT" then "update"
            when "DELETE" then "delete"
            when "HEAD" then "exists"
            else method_str.downcase
            end
          end
        end

        def extract_index(path)
          # Extract index name from path like /my-index/_search
          match = path.match(%r{^/([^/_]+)})
          match[1] if match && !match[1].start_with?("_")
        rescue StandardError
          nil
        end

        def truncate_path(path)
          return nil unless path
          path.to_s[0, 200]
        end
      end
    end
  end
end
