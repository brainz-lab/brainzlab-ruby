# frozen_string_literal: true

module BrainzLab
  module DevTools
    module Middleware
      class DatabaseHandler
        ENDPOINT = '/_brainzlab/devtools/database'

        def initialize(app)
          @app = app
        end

        def call(env)
          return @app.call(env) unless should_handle?(env)

          handle_database_request(env)
        end

        private

        def should_handle?(env)
          return false unless DevTools.enabled?
          return false unless DevTools.allowed_environment?
          return false unless DevTools.allowed_ip?(extract_ip(env))
          return false unless env['PATH_INFO'] == ENDPOINT
          return false unless env['REQUEST_METHOD'] == 'POST'

          true
        end

        def extract_ip(env)
          forwarded = env['HTTP_X_FORWARDED_FOR']
          return forwarded.split(',').first.strip if forwarded

          env['REMOTE_ADDR']
        end

        def handle_database_request(env)
          body = env['rack.input'].read
          env['rack.input'].rewind
          params = JSON.parse(body)
          action = params['action']

          result = case action
                   when 'migrate'
                     run_migrations
                   when 'status'
                     migration_status
                   when 'create'
                     create_database
                   when 'rollback'
                     rollback_migration
                   else
                     { success: false, output: "Unknown action: #{action}" }
                   end

          json_response(result)
        rescue StandardError => e
          json_response({ success: false, output: "Error: #{e.message}\n\n#{e.backtrace&.first(10)&.join("\n")}" })
        end

        def run_migrations
          return not_available('Rails') unless defined?(Rails)

          output = capture_output do
            ActiveRecord::MigrationContext.new(
              Rails.root.join('db/migrate'),
              ActiveRecord::SchemaMigration
            ).migrate
          end

          { success: true, output: output.presence || 'All migrations completed successfully!' }
        rescue StandardError => e
          { success: false, output: "Migration failed:\n#{e.message}\n\n#{e.backtrace&.first(10)&.join("\n")}" }
        end

        def migration_status
          return not_available('Rails') unless defined?(Rails)

          output = StringIO.new

          context = ActiveRecord::MigrationContext.new(
            Rails.root.join('db/migrate'),
            ActiveRecord::SchemaMigration
          )

          migrated = context.get_all_versions.to_set
          migrations = context.migrations

          output.puts "database: #{ActiveRecord::Base.connection_db_config.database}"
          output.puts ''
          output.puts ' Status   Migration ID    Migration Name'
          output.puts '-' * 60

          migrations.each do |migration|
            status = migrated.include?(migration.version) ? '   up' : ' down'
            output.puts " #{status}     #{migration.version}  #{migration.name}"
          end

          pending = migrations.reject { |m| migrated.include?(m.version) }
          output.puts ''
          if pending.any?
            output.puts "#{pending.count} pending migration(s)"
          else
            output.puts 'All migrations are up to date!'
          end

          { success: true, output: output.string }
        rescue StandardError => e
          { success: false, output: "Failed to check status:\n#{e.message}" }
        end

        def create_database
          return not_available('Rails') unless defined?(Rails)

          output = capture_output do
            ActiveRecord::Tasks::DatabaseTasks.create_current
          end

          { success: true, output: output.presence || 'Database created successfully!' }
        rescue ActiveRecord::DatabaseAlreadyExists
          { success: true, output: 'Database already exists.' }
        rescue StandardError => e
          { success: false, output: "Failed to create database:\n#{e.message}" }
        end

        def rollback_migration
          return not_available('Rails') unless defined?(Rails)

          output = capture_output do
            ActiveRecord::MigrationContext.new(
              Rails.root.join('db/migrate'),
              ActiveRecord::SchemaMigration
            ).rollback
          end

          { success: true, output: output.presence || 'Rollback completed!' }
        rescue StandardError => e
          { success: false, output: "Rollback failed:\n#{e.message}" }
        end

        def capture_output
          original_stdout = $stdout
          original_stderr = $stderr
          captured = StringIO.new
          $stdout = captured
          $stderr = captured

          yield

          captured.string
        ensure
          $stdout = original_stdout
          $stderr = original_stderr
        end

        def not_available(framework)
          { success: false, output: "#{framework} is not available." }
        end

        def json_response(data)
          body = JSON.generate(data)
          [
            200,
            {
              'Content-Type' => 'application/json; charset=utf-8',
              'Content-Length' => body.bytesize.to_s,
              'Cache-Control' => 'no-store',
              'X-Content-Type-Options' => 'nosniff'
            },
            [body]
          ]
        end
      end
    end
  end
end
