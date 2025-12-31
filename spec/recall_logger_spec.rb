# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab::Recall::Logger do
  let(:logger) { described_class.new }

  before do
    BrainzLab.configure do |config|
      config.secret_key = 'test_key'
      config.recall_enabled = true
    end

    stub_request(:post, 'https://recall.brainzlab.ai/api/v1/logs')
      .to_return(status: 201, body: '{"ingested": 1}')
  end

  describe '#initialize' do
    it 'creates logger without service name' do
      logger = described_class.new

      expect(logger).to be_a(Logger)
    end

    it 'creates logger with service name' do
      logger = described_class.new('api-service')

      expect(logger.instance_variable_get(:@service_name)).to eq('api-service')
    end

    it 'accepts broadcast_to logger' do
      original_logger = Logger.new($stdout)
      logger = described_class.new('service', broadcast_to: original_logger)

      expect(logger.broadcast_to).to eq(original_logger)
    end
  end

  describe '#add' do
    it 'logs message to Recall' do
      logger.add(Logger::INFO, 'Test message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'info' && log['message'] == 'Test message'
        end)
    end

    it 'broadcasts to original logger' do
      original_logger = double('logger')
      expect(original_logger).to receive(:add).with(Logger::INFO, 'Test message', nil)

      logger = described_class.new(broadcast_to: original_logger)
      logger.add(Logger::INFO, 'Test message')
    end

    it 'handles block-based messages' do
      logger.add(Logger::INFO) { 'Block message' }
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['message'] == 'Block message'
        end)
    end

    it 'handles progname as message' do
      logger.add(Logger::INFO, nil, 'Progname message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['message'] == 'Progname message'
        end)
    end

    it 'respects log level' do
      logger.level = Logger::WARN

      logger.add(Logger::DEBUG, 'Debug message')
      logger.add(Logger::INFO, 'Info message')
      logger.add(Logger::WARN, 'Warn message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].size == 1 &&
            body['logs'].first['level'] == 'warn'
        end)
    end

    it 'extracts structured data from hash message' do
      logger.add(Logger::INFO, { message: 'Structured log', user_id: 123, action: 'login' })
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['message'] == 'Structured log' &&
            log['data']['user_id'] == 123 &&
            log['data']['action'] == 'login'
        end)
    end

    it 'includes service name when configured' do
      logger = described_class.new('test-service')
      logger.add(Logger::INFO, 'Test message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['data']['service'] == 'test-service'
        end)
    end

    it 'includes progname in data when provided with message' do
      logger.add(Logger::INFO, 'Test message', 'MyProgram')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['data']['progname'] == 'MyProgram'
        end)
    end
  end

  describe '#debug' do
    it 'logs at debug level' do
      logger.debug('Debug message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'debug'
        end)
    end

    it 'accepts block' do
      logger.debug { 'Debug from block' }
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['message'] == 'Debug from block'
        end)
    end
  end

  describe '#info' do
    it 'logs at info level' do
      logger.info('Info message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'info'
        end)
    end
  end

  describe '#warn' do
    it 'logs at warn level' do
      logger.warn('Warning message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'warn'
        end)
    end
  end

  describe '#error' do
    it 'logs at error level' do
      logger.error('Error message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'error'
        end)
    end
  end

  describe '#fatal' do
    it 'logs at fatal level' do
      logger.fatal('Fatal message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'fatal'
        end)
    end
  end

  describe '#unknown' do
    it 'logs at fatal level for unknown severity' do
      logger.unknown('Unknown message')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['level'] == 'fatal'
        end)
    end
  end

  describe '#silence' do
    it 'temporarily changes log level' do
      logger.level = Logger::INFO

      logger.silence(Logger::ERROR) do
        logger.info('This should be silenced')
        logger.error('This should log')
      end

      logger.info('This should log again')

      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].size == 2 &&
            body['logs'].all? { |log| log['level'] != 'info' || log['message'] == 'This should log again' }
        end)
    end

    it 'restores original level after block' do
      logger.level = Logger::INFO

      logger.silence(Logger::ERROR) do
        # Inside block
      end

      expect(logger.level).to eq(Logger::INFO)
    end

    it 'restores level even when block raises error' do
      logger.level = Logger::INFO

      expect do
        logger.silence(Logger::ERROR) do
          raise StandardError, 'Test error'
        end
      end.to raise_error(StandardError)

      expect(logger.level).to eq(Logger::INFO)
    end
  end

  describe '#tagged' do
    it 'adds tags to context within block' do
      logger.tagged('request', 'api') do
        logger.info('Tagged log')
      end

      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          log = body['logs'].first
          log['data']['tags'] == %w[request api]
        end)
    end

    it 'returns self when called without block' do
      result = logger.tagged('test')

      expect(result).to eq(logger)
    end
  end

  describe '#flush' do
    it 'flushes Recall buffer' do
      logger.info('Test message')

      expect(WebMock).not_to have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')

      logger.flush

      expect(WebMock).to have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
    end
  end

  describe '#close' do
    it 'flushes buffer on close' do
      logger.info('Test message')

      logger.close

      expect(WebMock).to have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
    end
  end

  describe 'severity mapping' do
    it 'maps Logger::DEBUG to :debug' do
      logger.add(Logger::DEBUG, 'Test')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].first['level'] == 'debug'
        end)
    end

    it 'maps Logger::INFO to :info' do
      logger.add(Logger::INFO, 'Test')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].first['level'] == 'info'
        end)
    end

    it 'maps Logger::WARN to :warn' do
      logger.add(Logger::WARN, 'Test')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].first['level'] == 'warn'
        end)
    end

    it 'maps Logger::ERROR to :error' do
      logger.add(Logger::ERROR, 'Test')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].first['level'] == 'error'
        end)
    end

    it 'maps Logger::FATAL to :fatal' do
      logger.add(Logger::FATAL, 'Test')
      BrainzLab::Recall.flush

      expect(WebMock).to(have_requested(:post, 'https://recall.brainzlab.ai/api/v1/logs')
        .with do |req|
          body = JSON.parse(req.body)
          body['logs'].first['level'] == 'fatal'
        end)
    end
  end
end
