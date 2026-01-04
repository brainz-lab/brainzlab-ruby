# frozen_string_literal: true

require 'spec_helper'
require 'brainzlab/instrumentation/active_job'

# Mock ActiveJob for testing
module ActiveJob; end

RSpec.describe BrainzLab::Instrumentation::ActiveJob do
  let(:job_mock) do
    double('Job',
           class: double(name: 'ProcessOrderJob'),
           job_id: 'job-123',
           queue_name: 'default',
           executions: 1,
           enqueued_at: Time.now - 5,
           scheduled_at: nil)
  end

  before do
    ActiveSupport::Notifications.clear!

    BrainzLab.configure do |c|
      c.secret_key = 'test_key'
      c.recall_enabled = true
      c.reflex_enabled = true
      c.pulse_enabled = true
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

    # Clear thread-local storage
    Thread.current[:brainzlab_job_starts] = nil
  end

  describe '.install!' do
    it 'subscribes to ActiveJob events' do
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['enqueue.active_job']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['enqueue_at.active_job']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['enqueue_retry.active_job']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['perform_start.active_job']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['perform.active_job']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['retry_stopped.active_job']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['discard.active_job']).not_to be_empty
    end

    it 'is idempotent' do
      described_class.install!
      count = ActiveSupport::Notifications.subscribers['enqueue.active_job'].size
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['enqueue.active_job'].size).to eq(count)
    end

    it 'reports installed status' do
      expect(described_class.installed?).to be false
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe 'enqueue.active_job instrumentation' do
    before { described_class.install! }

    def emit_enqueue(job:)
      adapter = double('Adapter', class: double(name: 'ActiveJob::QueueAdapters::SidekiqAdapter'))
      payload = { job: job, adapter: adapter }

      ActiveSupport::Notifications.publish(
        'enqueue.active_job',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for job enqueue' do
      emit_enqueue(job: job_mock)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      job_crumb = crumbs.find { |c| c[:category] == 'job.enqueue' }

      expect(job_crumb).not_to be_nil
      expect(job_crumb[:message]).to include('ProcessOrderJob')
      expect(job_crumb[:level]).to eq('info')
      expect(job_crumb[:data][:job_class]).to eq('ProcessOrderJob')
      expect(job_crumb[:data][:job_id]).to eq('job-123')
      expect(job_crumb[:data][:queue]).to eq('default')
    end

    it 'adds Pulse span when trace is active' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_enqueue(job: job_mock)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      job_span = spans.find { |s| s[:name].start_with?('job.enqueue') }
      expect(job_span).not_to be_nil
      expect(job_span[:kind]).to eq('job')
      expect(job_span[:data]['job.class']).to eq('ProcessOrderJob')

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'enqueue_at.active_job instrumentation' do
    before { described_class.install! }

    def emit_enqueue_at(job:)
      payload = { job: job }

      ActiveSupport::Notifications.publish(
        'enqueue_at.active_job',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for scheduled job' do
      scheduled_job = double('Job',
                             class: double(name: 'SendReminderJob'),
                             job_id: 'job-456',
                             queue_name: 'mailers',
                             scheduled_at: Time.now + 3600)

      emit_enqueue_at(job: scheduled_job)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      job_crumb = crumbs.find { |c| c[:category] == 'job.schedule' }

      expect(job_crumb).not_to be_nil
      expect(job_crumb[:message]).to include('SendReminderJob')
      expect(job_crumb[:message]).to include('60.0min')
    end
  end

  describe 'enqueue_retry.active_job instrumentation' do
    before { described_class.install! }

    def emit_enqueue_retry(job:, error:, wait: 30)
      payload = { job: job, error: error, wait: wait }

      ActiveSupport::Notifications.publish(
        'enqueue_retry.active_job',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds warning breadcrumb for retry' do
      error = StandardError.new('Connection timeout')
      retry_job = double('Job',
                         class: double(name: 'ProcessOrderJob'),
                         job_id: 'job-123',
                         executions: 2)

      emit_enqueue_retry(job: retry_job, error: error, wait: 60)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      job_crumb = crumbs.find { |c| c[:category] == 'job.retry' }

      expect(job_crumb).not_to be_nil
      expect(job_crumb[:level]).to eq('warning')
      expect(job_crumb[:message]).to include('attempt 3')
      expect(job_crumb[:data][:error_class]).to eq('StandardError')
      expect(job_crumb[:data][:wait_seconds]).to eq(60)
    end
  end

  describe 'perform_start.active_job instrumentation' do
    before { described_class.install! }

    def emit_perform_start(job:)
      payload = { job: job }

      ActiveSupport::Notifications.publish(
        'perform_start.active_job',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for job start' do
      emit_perform_start(job: job_mock)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      job_crumb = crumbs.find { |c| c[:category] == 'job.start' }

      expect(job_crumb).not_to be_nil
      expect(job_crumb[:message]).to include('started')
      expect(job_crumb[:message]).to include('ProcessOrderJob')
    end

    it 'calculates queue wait time' do
      emit_perform_start(job: job_mock)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      job_crumb = crumbs.find { |c| c[:category] == 'job.start' }

      expect(job_crumb[:data][:queue_wait_ms]).to be_a(Numeric)
      expect(job_crumb[:data][:queue_wait_ms]).to be > 0
    end
  end

  describe 'perform.active_job instrumentation' do
    before { described_class.install! }

    def emit_perform(job:, exception: nil, duration_seconds: 0.5)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        job: job,
        exception_object: exception
      }

      ActiveSupport::Notifications.publish(
        'perform.active_job',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    context 'successful job' do
      it 'adds info breadcrumb for completed job' do
        emit_perform(job: job_mock)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        job_crumb = crumbs.find { |c| c[:category] == 'job.perform' }

        expect(job_crumb).not_to be_nil
        expect(job_crumb[:message]).to include('completed')
        expect(job_crumb[:level]).to eq('info')
        expect(job_crumb[:data][:error]).to be false
      end

      it 'sets warning level for slow jobs' do
        emit_perform(job: job_mock, duration_seconds: 6.0)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        job_crumb = crumbs.find { |c| c[:category] == 'job.perform' }

        expect(job_crumb[:level]).to eq('warning')
      end
    end

    context 'failed job' do
      it 'adds error breadcrumb for failed job' do
        error = StandardError.new('Processing failed')
        emit_perform(job: job_mock, exception: error)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        job_crumb = crumbs.find { |c| c[:category] == 'job.perform' }

        expect(job_crumb).not_to be_nil
        expect(job_crumb[:message]).to include('failed')
        expect(job_crumb[:level]).to eq('error')
        expect(job_crumb[:data][:error]).to be true
        expect(job_crumb[:data][:error_class]).to eq('StandardError')
      end
    end
  end

  describe 'retry_stopped.active_job instrumentation' do
    before { described_class.install! }

    def emit_retry_stopped(job:, error:)
      payload = { job: job, error: error }

      ActiveSupport::Notifications.publish(
        'retry_stopped.active_job',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds error breadcrumb for exhausted retries' do
      error = StandardError.new('Permanent failure')
      exhausted_job = double('Job',
                             class: double(name: 'ProcessOrderJob'),
                             job_id: 'job-123',
                             executions: 5)

      emit_retry_stopped(job: exhausted_job, error: error)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      job_crumb = crumbs.find { |c| c[:category] == 'job.retry_stopped' }

      expect(job_crumb).not_to be_nil
      expect(job_crumb[:level]).to eq('error')
      expect(job_crumb[:message]).to include('5 attempts')
      expect(job_crumb[:data][:executions]).to eq(5)
    end
  end

  describe 'discard.active_job instrumentation' do
    before { described_class.install! }

    def emit_discard(job:, error:)
      payload = { job: job, error: error }

      ActiveSupport::Notifications.publish(
        'discard.active_job',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds error breadcrumb for discarded job' do
      error = ArgumentError.new('Invalid input')
      emit_discard(job: job_mock, error: error)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      job_crumb = crumbs.find { |c| c[:category] == 'job.discard' }

      expect(job_crumb).not_to be_nil
      expect(job_crumb[:level]).to eq('error')
      expect(job_crumb[:message]).to include('discarded')
      expect(job_crumb[:data][:error_class]).to eq('ArgumentError')
    end
  end
end
