# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BrainzLab::Context do
  let(:context) { described_class.new }

  describe '.current' do
    it 'returns the current thread-local context' do
      expect(described_class.current).to be_a(described_class)
    end

    it 'creates a new context if none exists' do
      Thread.current[:brainzlab_context] = nil
      context = described_class.current
      expect(context).to be_a(described_class)
    end

    it 'returns the same context for the same thread' do
      ctx1 = described_class.current
      ctx2 = described_class.current
      expect(ctx1).to equal(ctx2)
    end
  end

  describe '.clear!' do
    it 'clears the current context' do
      described_class.current.set_user(id: 123)
      described_class.clear!
      new_context = described_class.current
      expect(new_context.user).to be_empty
    end
  end

  describe '#initialize' do
    it 'initializes with empty values' do
      expect(context.user).to eq({})
      expect(context.extra).to eq({})
      expect(context.tags).to eq({})
      expect(context.request_id).to be_nil
    end

    it 'initializes breadcrumbs' do
      expect(context.breadcrumbs).to be_a(BrainzLab::Reflex::Breadcrumbs)
    end
  end

  describe '#set_user' do
    it 'sets user with id, email, and name' do
      context.set_user(id: 123, email: 'test@example.com', name: 'Test User')

      expect(context.user[:id]).to eq(123)
      expect(context.user[:email]).to eq('test@example.com')
      expect(context.user[:name]).to eq('Test User')
    end

    it 'merges extra user attributes' do
      context.set_user(id: 123, role: 'admin', department: 'Engineering')

      expect(context.user[:id]).to eq(123)
      expect(context.user[:role]).to eq('admin')
      expect(context.user[:department]).to eq('Engineering')
    end

    it 'omits nil values' do
      context.set_user(id: 123, email: nil)

      expect(context.user).to eq({ id: 123 })
    end

    it 'replaces previous user data' do
      context.set_user(id: 123, email: 'old@example.com')
      context.set_user(id: 456, email: 'new@example.com')

      expect(context.user[:id]).to eq(456)
      expect(context.user[:email]).to eq('new@example.com')
    end
  end

  describe '#set_context' do
    it 'adds context data' do
      context.set_context(deployment: 'v1.0', region: 'us-east-1')

      expect(context.extra[:deployment]).to eq('v1.0')
      expect(context.extra[:region]).to eq('us-east-1')
    end

    it 'merges with existing context' do
      context.set_context(foo: 'bar')
      context.set_context(baz: 'qux')

      expect(context.extra[:foo]).to eq('bar')
      expect(context.extra[:baz]).to eq('qux')
    end

    it 'overwrites existing keys' do
      context.set_context(version: '1.0')
      context.set_context(version: '2.0')

      expect(context.extra[:version]).to eq('2.0')
    end
  end

  describe '#set_tags' do
    it 'adds tags' do
      context.set_tags(env: 'production', server: 'web-01')

      expect(context.tags[:env]).to eq('production')
      expect(context.tags[:server]).to eq('web-01')
    end

    it 'merges with existing tags' do
      context.set_tags(foo: 'bar')
      context.set_tags(baz: 'qux')

      expect(context.tags[:foo]).to eq('bar')
      expect(context.tags[:baz]).to eq('qux')
    end
  end

  describe '#with_context' do
    it 'temporarily adds context within block' do
      context.set_context(base: 'value')

      result = context.with_context(scoped: 'temp') do
        expect(context.data_hash[:base]).to eq('value')
        expect(context.data_hash[:scoped]).to eq('temp')
        'return_value'
      end

      expect(result).to eq('return_value')
      expect(context.data_hash[:scoped]).to be_nil
      expect(context.data_hash[:base]).to eq('value')
    end

    it 'handles nested with_context calls' do
      context.with_context(level1: 'a') do
        context.with_context(level2: 'b') do
          expect(context.data_hash[:level1]).to eq('a')
          expect(context.data_hash[:level2]).to eq('b')
        end

        expect(context.data_hash[:level1]).to eq('a')
        expect(context.data_hash[:level2]).to be_nil
      end

      expect(context.data_hash[:level1]).to be_nil
    end

    it 'pops context even when block raises error' do
      context.set_context(base: 'value')

      expect do
        context.with_context(scoped: 'temp') do
          raise StandardError, 'Test error'
        end
      end.to raise_error(StandardError)

      expect(context.data_hash[:scoped]).to be_nil
      expect(context.data_hash[:base]).to eq('value')
    end
  end

  describe '#to_hash' do
    it 'returns empty hash when no data is set' do
      expect(context.to_hash).to eq({})
    end

    it 'includes request_id when set' do
      context.request_id = 'req-123'

      expect(context.to_hash[:request_id]).to eq('req-123')
    end

    it 'includes session_id when set' do
      context.session_id = 'sess-456'

      expect(context.to_hash[:session_id]).to eq('sess-456')
    end

    it 'includes user when set' do
      context.set_user(id: 123, email: 'test@example.com')

      expect(context.to_hash[:user]).to eq({ id: 123, email: 'test@example.com' })
    end

    it 'includes tags when set' do
      context.set_tags(env: 'prod')

      expect(context.to_hash[:tags]).to eq({ env: 'prod' })
    end

    it 'includes context data' do
      context.set_context(deployment: 'v1.0')

      expect(context.to_hash[:context]).to eq({ deployment: 'v1.0' })
    end

    it 'merges scoped context' do
      context.set_context(base: 'value')

      context.with_context(scoped: 'temp') do
        hash = context.to_hash
        expect(hash[:context]).to eq({ base: 'value', scoped: 'temp' })
      end
    end
  end

  describe '#data_hash' do
    it 'merges extra, user, and tags' do
      context.set_user(id: 123)
      context.set_tags(env: 'prod')
      context.set_context(deployment: 'v1.0')

      data = context.data_hash

      expect(data[:user]).to eq({ id: 123 })
      expect(data[:tags]).to eq({ env: 'prod' })
      expect(data[:deployment]).to eq('v1.0')
    end

    it 'includes scoped context' do
      context.set_context(base: 'value')

      context.with_context(scoped: 'temp') do
        expect(context.data_hash[:scoped]).to eq('temp')
      end
    end
  end

  describe 'request attributes' do
    it 'stores request method' do
      context.request_method = 'POST'
      expect(context.request_method).to eq('POST')
    end

    it 'stores request path' do
      context.request_path = '/users/123'
      expect(context.request_path).to eq('/users/123')
    end

    it 'stores request URL' do
      context.request_url = 'https://example.com/users/123'
      expect(context.request_url).to eq('https://example.com/users/123')
    end

    it 'stores request params' do
      context.request_params = { name: 'John' }
      expect(context.request_params).to eq({ name: 'John' })
    end

    it 'stores request headers' do
      context.request_headers = { 'User-Agent' => 'Test' }
      expect(context.request_headers).to eq({ 'User-Agent' => 'Test' })
    end

    it 'stores controller and action' do
      context.controller = 'UsersController'
      context.action = 'create'

      expect(context.controller).to eq('UsersController')
      expect(context.action).to eq('create')
    end
  end
end
