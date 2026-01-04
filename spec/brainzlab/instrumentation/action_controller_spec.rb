# frozen_string_literal: true

require 'spec_helper'
require 'brainzlab/instrumentation/action_controller'

# Mock ActionController for testing
module ActionController; end

RSpec.describe BrainzLab::Instrumentation::ActionController do
  before do
    ActiveSupport::Notifications.clear!

    BrainzLab.configure do |c|
      c.secret_key = 'test_key'
      c.recall_enabled = true
      c.reflex_enabled = true
      c.pulse_enabled = true
      c.pulse_excluded_paths = %w[/health /ping /up /assets]
    end

    # Stub all API calls
    stub_request(:post, %r{recall\.brainzlab\.ai})
      .to_return(status: 200, body: '{}')
    stub_request(:post, %r{reflex\.brainzlab\.ai})
      .to_return(status: 200, body: '{}')
    stub_request(:post, %r{pulse\.brainzlab\.ai})
      .to_return(status: 200, body: '{}')

    # Reset the installed flag for testing
    described_class.instance_variable_set(:@installed, false)
  end

  describe '.install!' do
    it 'subscribes to ActionController events' do
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['process_action.action_controller']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['redirect_to.action_controller']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['halted_callback.action_controller']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['unpermitted_parameters.action_controller']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['send_file.action_controller']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['send_data.action_controller']).not_to be_empty
    end

    it 'is idempotent' do
      described_class.install!
      count = ActiveSupport::Notifications.subscribers['process_action.action_controller'].size
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['process_action.action_controller'].size).to eq(count)
    end

    it 'reports installed status' do
      expect(described_class.installed?).to be false
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe 'process_action.action_controller instrumentation' do
    before { described_class.install! }

    def emit_process_action(controller:, action:, method: 'GET', path: '/users', status: 200, duration_seconds: 0.1, **extra)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        controller: controller,
        action: action,
        method: method,
        path: path,
        status: status,
        format: :html,
        view_runtime: 50.0,
        db_runtime: 25.0,
        **extra
      }

      ActiveSupport::Notifications.publish(
        'process_action.action_controller',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    context 'breadcrumbs' do
      it 'adds breadcrumb for successful requests' do
        emit_process_action(controller: 'UsersController', action: 'index', status: 200)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb).not_to be_nil
        expect(request_crumb[:message]).to include('UsersController#index')
        expect(request_crumb[:message]).to include('200')
        expect(request_crumb[:level]).to eq('info')
        expect(request_crumb[:data][:controller]).to eq('UsersController')
        expect(request_crumb[:data][:action]).to eq('index')
      end

      it 'sets warning level for 4xx responses' do
        emit_process_action(controller: 'UsersController', action: 'show', status: 404)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb[:level]).to eq('warning')
      end

      it 'sets error level for 5xx responses' do
        emit_process_action(controller: 'UsersController', action: 'create', status: 500)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb[:level]).to eq('error')
      end

      it 'sets warning level for slow requests' do
        emit_process_action(controller: 'UsersController', action: 'index', status: 200, duration_seconds: 0.6)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb[:level]).to eq('warning')
      end

      it 'sets error level for very slow requests' do
        emit_process_action(controller: 'UsersController', action: 'index', status: 200, duration_seconds: 2.5)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb[:level]).to eq('error')
      end

      it 'includes timing breakdown' do
        emit_process_action(controller: 'UsersController', action: 'index')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb[:data][:view_ms]).to eq(50.0)
        expect(request_crumb[:data][:db_ms]).to eq(25.0)
      end
    end

    context 'excluded paths' do
      it 'skips health check endpoints' do
        emit_process_action(controller: 'HealthController', action: 'show', path: '/health')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb).to be_nil
      end

      it 'skips asset paths' do
        emit_process_action(controller: 'AssetsController', action: 'show', path: '/assets/application.js')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        request_crumb = crumbs.find { |c| c[:category] == 'http.request' }

        expect(request_crumb).to be_nil
      end
    end
  end

  describe 'redirect_to.action_controller instrumentation' do
    before { described_class.install! }

    def emit_redirect(location:, status: 302)
      ActiveSupport::Notifications.publish(
        'redirect_to.action_controller',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        { location: location, status: status }
      )
    end

    it 'adds breadcrumb for redirects' do
      emit_redirect(location: '/users/1')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      redirect_crumb = crumbs.find { |c| c[:category] == 'http.redirect' }

      expect(redirect_crumb).not_to be_nil
      expect(redirect_crumb[:message]).to include('/users/1')
      expect(redirect_crumb[:message]).to include('302')
      expect(redirect_crumb[:level]).to eq('info')
    end

    it 'includes status code in data' do
      emit_redirect(location: '/login', status: 301)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      redirect_crumb = crumbs.find { |c| c[:category] == 'http.redirect' }

      expect(redirect_crumb[:data][:status]).to eq(301)
    end
  end

  describe 'halted_callback.action_controller instrumentation' do
    before { described_class.install! }

    def emit_halted_callback(filter:)
      ActiveSupport::Notifications.publish(
        'halted_callback.action_controller',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        { filter: filter }
      )
    end

    it 'adds breadcrumb for halted callbacks' do
      emit_halted_callback(filter: :authenticate_user!)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      halted_crumb = crumbs.find { |c| c[:category] == 'http.filter' }

      expect(halted_crumb).not_to be_nil
      expect(halted_crumb[:message]).to include('authenticate_user!')
      expect(halted_crumb[:level]).to eq('warning')
    end
  end

  describe 'unpermitted_parameters.action_controller instrumentation' do
    before { described_class.install! }

    def emit_unpermitted_parameters(keys:, context: {})
      ActiveSupport::Notifications.publish(
        'unpermitted_parameters.action_controller',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        { keys: keys, context: context }
      )
    end

    it 'adds breadcrumb for unpermitted parameters' do
      emit_unpermitted_parameters(keys: %w[admin role])

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      params_crumb = crumbs.find { |c| c[:category] == 'security.params' }

      expect(params_crumb).not_to be_nil
      expect(params_crumb[:message]).to include('admin')
      expect(params_crumb[:message]).to include('role')
      expect(params_crumb[:level]).to eq('warning')
    end

    it 'includes context information' do
      emit_unpermitted_parameters(
        keys: %w[admin],
        context: { controller: 'UsersController', action: 'update' }
      )

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      params_crumb = crumbs.find { |c| c[:category] == 'security.params' }

      expect(params_crumb[:data][:controller]).to eq('UsersController')
      expect(params_crumb[:data][:action]).to eq('update')
    end

    it 'does not add breadcrumb for empty keys' do
      emit_unpermitted_parameters(keys: [])

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      params_crumb = crumbs.find { |c| c[:category] == 'security.params' }

      expect(params_crumb).to be_nil
    end
  end

  describe 'send_file.action_controller instrumentation' do
    before { described_class.install! }

    def emit_send_file(path:)
      ActiveSupport::Notifications.publish(
        'send_file.action_controller',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        { path: path }
      )
    end

    it 'adds breadcrumb for file sends' do
      emit_send_file(path: '/uploads/report.pdf')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      file_crumb = crumbs.find { |c| c[:category] == 'http.file' }

      expect(file_crumb).not_to be_nil
      expect(file_crumb[:message]).to include('report.pdf')
      expect(file_crumb[:level]).to eq('info')
    end
  end

  describe 'send_data.action_controller instrumentation' do
    before { described_class.install! }

    def emit_send_data(filename: nil)
      ActiveSupport::Notifications.publish(
        'send_data.action_controller',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        { filename: filename }
      )
    end

    it 'adds breadcrumb for data sends with filename' do
      emit_send_data(filename: 'export.csv')

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      data_crumb = crumbs.find { |c| c[:category] == 'http.data' }

      expect(data_crumb).not_to be_nil
      expect(data_crumb[:message]).to include('export.csv')
    end

    it 'adds breadcrumb for data sends without filename' do
      emit_send_data(filename: nil)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      data_crumb = crumbs.find { |c| c[:category] == 'http.data' }

      expect(data_crumb).not_to be_nil
      expect(data_crumb[:message]).to include('Sending data')
    end
  end

  describe 'helper methods' do
    describe '.truncate_path' do
      it 'truncates long paths' do
        long_path = '/users/' + ('a' * 250)
        result = described_class.send(:truncate_path, long_path, 100)
        expect(result.length).to eq(100)
        expect(result).to end_with('...')
      end

      it 'leaves short paths unchanged' do
        result = described_class.send(:truncate_path, '/users/1')
        expect(result).to eq('/users/1')
      end

      it 'handles nil' do
        result = described_class.send(:truncate_path, nil)
        expect(result).to be_nil
      end
    end

    describe '.excluded_path?' do
      it 'returns true for excluded paths' do
        expect(described_class.send(:excluded_path?, '/health')).to be true
        expect(described_class.send(:excluded_path?, '/ping')).to be true
        expect(described_class.send(:excluded_path?, '/assets/app.js')).to be true
      end

      it 'returns false for regular paths' do
        expect(described_class.send(:excluded_path?, '/users')).to be false
        expect(described_class.send(:excluded_path?, '/api/v1/items')).to be false
      end
    end
  end
end
