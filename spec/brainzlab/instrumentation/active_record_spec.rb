# frozen_string_literal: true

require 'spec_helper'
require 'brainzlab/instrumentation/active_record'

# Mock ActiveSupport::Notifications for testing
module ActiveSupport
  module Notifications
    class Event
      attr_reader :name, :time, :end, :payload, :duration

      def initialize(name, start_time, end_time, _id, payload)
        @name = name
        @time = start_time
        @end = end_time
        @payload = payload
        @duration = (end_time - start_time) * 1000
      end
    end

    class << self
      def subscribers
        @subscribers ||= {}
      end

      def subscribe(event_name, &block)
        subscribers[event_name] ||= []
        subscribers[event_name] << block
      end

      def instrument(name, payload = {})
        start_time = Time.now
        result = yield if block_given?
        end_time = Time.now

        subscribers[name]&.each do |callback|
          event = Event.new(name, start_time, end_time, SecureRandom.hex(8), payload)
          callback.call(name, start_time, end_time, SecureRandom.hex(8), payload)
        end

        result
      end

      def publish(name, start_time, end_time, id, payload)
        subscribers[name]&.each do |callback|
          callback.call(name, start_time, end_time, id, payload)
        end
      end

      def clear!
        @subscribers = {}
      end
    end
  end
end

# Mock ActiveRecord module
module ActiveRecord; end

RSpec.describe BrainzLab::Instrumentation::ActiveRecord do
  let(:connection_mock) do
    double('Connection',
           pool: double('Pool',
                        db_config: double('DbConfig',
                                          name: 'primary',
                                          adapter: 'postgresql',
                                          database: 'myapp_development')),
           adapter_name: 'PostgreSQL')
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
  end

  after do
    Thread.current[:brainzlab_query_tracker] = nil
    Thread.current[:brainzlab_transaction_starts] = nil
  end

  describe '.install!' do
    it 'subscribes to ActiveRecord events' do
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['sql.active_record']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['instantiation.active_record']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['start_transaction.active_record']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['transaction.active_record']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['strict_loading_violation.active_record']).not_to be_empty
    end

    it 'is idempotent' do
      described_class.install!
      count = ActiveSupport::Notifications.subscribers['sql.active_record'].size
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['sql.active_record'].size).to eq(count)
    end

    it 'reports installed status' do
      expect(described_class.installed?).to be false
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe 'sql.active_record instrumentation' do
    before { described_class.install! }

    def emit_sql_event(sql:, name: 'User Load', duration_seconds: 0.005, cached: false, **extra)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        sql: sql,
        name: name,
        cached: cached,
        connection: connection_mock,
        **extra
      }

      ActiveSupport::Notifications.publish(
        'sql.active_record',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    context 'breadcrumbs' do
      it 'adds breadcrumb for SELECT queries' do
        emit_sql_event(sql: 'SELECT * FROM users WHERE id = 1')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.select' }

        expect(db_crumb).not_to be_nil
        expect(db_crumb[:message]).to include('User Load')
        expect(db_crumb[:level]).to eq('info')
        expect(db_crumb[:data][:sql]).to include('SELECT')
        expect(db_crumb[:data][:cached]).to be false
      end

      it 'marks cached queries' do
        emit_sql_event(sql: 'SELECT * FROM users', cached: true)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.select' }

        expect(db_crumb[:message]).to include('cached')
        expect(db_crumb[:data][:cached]).to be true
      end

      it 'categorizes INSERT queries' do
        emit_sql_event(sql: 'INSERT INTO users (name) VALUES ($1)', name: 'User Create')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.insert' }

        expect(db_crumb).not_to be_nil
      end

      it 'categorizes UPDATE queries' do
        emit_sql_event(sql: 'UPDATE users SET name = $1 WHERE id = $2', name: 'User Update')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.update' }

        expect(db_crumb).not_to be_nil
      end

      it 'categorizes DELETE queries' do
        emit_sql_event(sql: 'DELETE FROM users WHERE id = $1', name: 'User Destroy')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.delete' }

        expect(db_crumb).not_to be_nil
      end

      it 'sets warning level for slow queries (100-1000ms)' do
        emit_sql_event(sql: 'SELECT * FROM users', duration_seconds: 0.15)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.select' }

        expect(db_crumb[:level]).to eq('warning')
      end

      it 'sets error level for very slow queries (>1000ms)' do
        emit_sql_event(sql: 'SELECT * FROM users', duration_seconds: 1.5)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.select' }

        expect(db_crumb[:level]).to eq('error')
      end

      it 'includes row_count and affected_rows when available' do
        emit_sql_event(sql: 'SELECT * FROM users', row_count: 50, affected_rows: 0)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        db_crumb = crumbs.find { |c| c[:category] == 'db.select' }

        expect(db_crumb[:data][:row_count]).to eq(50)
      end
    end

    context 'Pulse spans' do
      it 'adds span when trace is active' do
        BrainzLab::Pulse.start_trace('test.request', kind: 'request')

        emit_sql_event(sql: 'SELECT * FROM users WHERE id = 1')

        tracer = BrainzLab::Pulse.tracer
        spans = tracer.current_spans

        db_span = spans.find { |s| s[:name] == 'db.select' }
        expect(db_span).not_to be_nil
        expect(db_span[:kind]).to eq('db')
        expect(db_span[:data]['db.system']).to eq('postgresql')
        expect(db_span[:data]['db.operation']).to eq('select')

        # Clean up trace
        BrainzLab::Pulse.finish_trace
      end

      it 'does not add span when no trace is active' do
        # Ensure no trace is active
        BrainzLab::Pulse.reset!

        emit_sql_event(sql: 'SELECT * FROM users')

        tracer = BrainzLab::Pulse.tracer
        # Should be nil or empty when no trace is active
        expect(tracer.current_spans).to satisfy { |spans| spans.nil? || spans.empty? }
      end
    end

    context 'skipped queries' do
      it 'skips SCHEMA queries' do
        emit_sql_event(sql: 'SELECT * FROM pg_tables', name: 'SCHEMA')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        expect(crumbs).to be_empty
      end

      it 'skips queries to internal tables' do
        emit_sql_event(sql: 'SELECT * FROM pg_class')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        expect(crumbs).to be_empty
      end

      it 'skips queries to information_schema' do
        emit_sql_event(sql: 'SELECT * FROM information_schema.tables')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        expect(crumbs).to be_empty
      end
    end
  end

  describe 'N+1 detection' do
    before { described_class.install! }

    def emit_sql_event(sql:, name: 'User Load')
      start_time = Time.now
      end_time = start_time + 0.005
      payload = { sql: sql, name: name, connection: connection_mock }

      ActiveSupport::Notifications.publish(
        'sql.active_record',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'detects N+1 pattern when threshold is reached' do
      # Emit 5 queries to the same table
      5.times do |i|
        emit_sql_event(sql: "SELECT * FROM posts WHERE user_id = #{i}")
      end

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      n_plus_one_crumb = crumbs.find { |c| c[:category] == 'db.n_plus_one' }

      expect(n_plus_one_crumb).not_to be_nil
      expect(n_plus_one_crumb[:message]).to include('posts')
      expect(n_plus_one_crumb[:level]).to eq('warning')
      expect(n_plus_one_crumb[:data][:table]).to eq('posts')
      expect(n_plus_one_crumb[:data][:query_count]).to eq(5)
    end

    it 'does not trigger for fewer than threshold queries' do
      3.times do |i|
        emit_sql_event(sql: "SELECT * FROM posts WHERE user_id = #{i}")
      end

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      n_plus_one_crumb = crumbs.find { |c| c[:category] == 'db.n_plus_one' }

      expect(n_plus_one_crumb).to be_nil
    end

    it 'tracks different tables separately' do
      3.times { |i| emit_sql_event(sql: "SELECT * FROM posts WHERE id = #{i}") }
      3.times { |i| emit_sql_event(sql: "SELECT * FROM comments WHERE id = #{i}") }

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      n_plus_one_crumb = crumbs.find { |c| c[:category] == 'db.n_plus_one' }

      expect(n_plus_one_crumb).to be_nil
    end

    it 'includes sample queries in the report' do
      5.times do |i|
        emit_sql_event(sql: "SELECT * FROM posts WHERE user_id = #{i}")
      end

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      n_plus_one_crumb = crumbs.find { |c| c[:category] == 'db.n_plus_one' }

      expect(n_plus_one_crumb[:data][:sample_queries]).to be_an(Array)
      expect(n_plus_one_crumb[:data][:sample_queries].size).to be <= 3
    end
  end

  describe 'instantiation.active_record instrumentation' do
    before { described_class.install! }

    def emit_instantiation_event(class_name:, record_count:, duration_seconds: 0.002)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { class_name: class_name, record_count: record_count }

      ActiveSupport::Notifications.publish(
        'instantiation.active_record',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for large instantiations (100+ records)' do
      emit_instantiation_event(class_name: 'User', record_count: 150)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      instantiate_crumb = crumbs.find { |c| c[:category] == 'db.instantiate' }

      expect(instantiate_crumb).not_to be_nil
      expect(instantiate_crumb[:message]).to include('150')
      expect(instantiate_crumb[:message]).to include('User')
      expect(instantiate_crumb[:level]).to eq('info')
    end

    it 'sets warning level for very large instantiations (1000+ records)' do
      emit_instantiation_event(class_name: 'User', record_count: 1500)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      instantiate_crumb = crumbs.find { |c| c[:category] == 'db.instantiate' }

      expect(instantiate_crumb[:level]).to eq('warning')
    end

    it 'does not add breadcrumb for small instantiations' do
      emit_instantiation_event(class_name: 'User', record_count: 10)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      instantiate_crumb = crumbs.find { |c| c[:category] == 'db.instantiate' }

      expect(instantiate_crumb).to be_nil
    end

    it 'adds Pulse span when trace is active' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_instantiation_event(class_name: 'User', record_count: 50)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      instantiate_span = spans.find { |s| s[:name] == 'db.instantiate.User' }
      expect(instantiate_span).not_to be_nil
      expect(instantiate_span[:data]['db.record_count']).to eq(50)
    end
  end

  describe 'transaction.active_record instrumentation' do
    before { described_class.install! }

    let(:transaction_mock) { double('Transaction') }

    def emit_transaction_start
      payload = { transaction: transaction_mock, connection: connection_mock }

      ActiveSupport::Notifications.publish(
        'start_transaction.active_record',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    def emit_transaction_complete(outcome:, duration_seconds: 0.05)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        transaction: transaction_mock,
        outcome: outcome,
        connection: connection_mock
      }

      ActiveSupport::Notifications.publish(
        'transaction.active_record',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'tracks transaction commit' do
      emit_transaction_start
      emit_transaction_complete(outcome: :commit)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      tx_crumb = crumbs.find { |c| c[:category] == 'db.transaction' }

      expect(tx_crumb).not_to be_nil
      expect(tx_crumb[:message]).to include('commit')
      expect(tx_crumb[:level]).to eq('info')
      expect(tx_crumb[:data][:outcome]).to eq('commit')
    end

    it 'tracks transaction rollback with warning level' do
      emit_transaction_start
      emit_transaction_complete(outcome: :rollback)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      tx_crumb = crumbs.find { |c| c[:category] == 'db.transaction' }

      expect(tx_crumb[:message]).to include('rollback')
      expect(tx_crumb[:level]).to eq('warning')
    end

    it 'tracks incomplete transactions with error level' do
      emit_transaction_start
      emit_transaction_complete(outcome: :incomplete)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      tx_crumb = crumbs.find { |c| c[:category] == 'db.transaction' }

      expect(tx_crumb[:level]).to eq('error')
    end

    it 'adds Pulse span for transactions' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_transaction_start
      emit_transaction_complete(outcome: :commit)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      tx_span = spans.find { |s| s[:name] == 'db.transaction' }
      expect(tx_span).not_to be_nil
      expect(tx_span[:data]['db.transaction.outcome']).to eq('commit')
      expect(tx_span[:error]).to be false
    end

    it 'marks rollback spans as errors' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_transaction_start
      emit_transaction_complete(outcome: :rollback)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      tx_span = spans.find { |s| s[:name] == 'db.transaction' }
      expect(tx_span[:error]).to be true
    end
  end

  describe 'strict_loading_violation.active_record instrumentation' do
    before { described_class.install! }

    let(:owner_mock) { double('User', class: double(name: 'User')) }
    let(:reflection_mock) { double('Reflection', name: :posts, class: double(name: 'ActiveRecord::Reflection::HasManyReflection')) }

    def emit_strict_loading_violation
      payload = { owner: owner_mock, reflection: reflection_mock }

      ActiveSupport::Notifications.publish(
        'strict_loading_violation.active_record',
        Time.now,
        Time.now,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for strict loading violations' do
      emit_strict_loading_violation

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      violation_crumb = crumbs.find { |c| c[:category] == 'db.strict_loading' }

      expect(violation_crumb).not_to be_nil
      expect(violation_crumb[:message]).to include('User')
      expect(violation_crumb[:message]).to include('posts')
      expect(violation_crumb[:level]).to eq('warning')
    end

    it 'includes violation details in data' do
      emit_strict_loading_violation

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      violation_crumb = crumbs.find { |c| c[:category] == 'db.strict_loading' }

      expect(violation_crumb[:data][:owner_class]).to eq('User')
      expect(violation_crumb[:data][:association]).to eq('posts')
    end
  end

  describe 'helper methods' do
    describe '.extract_operation' do
      it 'extracts SELECT operation' do
        result = described_class.send(:extract_operation, 'SELECT * FROM users')
        expect(result).to eq('select')
      end

      it 'extracts INSERT operation' do
        result = described_class.send(:extract_operation, 'INSERT INTO users VALUES (1)')
        expect(result).to eq('insert')
      end

      it 'extracts UPDATE operation' do
        result = described_class.send(:extract_operation, 'UPDATE users SET name = $1')
        expect(result).to eq('update')
      end

      it 'extracts DELETE operation' do
        result = described_class.send(:extract_operation, 'DELETE FROM users')
        expect(result).to eq('delete')
      end

      it 'extracts BEGIN transaction' do
        result = described_class.send(:extract_operation, 'BEGIN')
        expect(result).to eq('transaction.begin')
      end

      it 'extracts COMMIT transaction' do
        result = described_class.send(:extract_operation, 'COMMIT')
        expect(result).to eq('transaction.commit')
      end

      it 'extracts ROLLBACK transaction' do
        result = described_class.send(:extract_operation, 'ROLLBACK')
        expect(result).to eq('transaction.rollback')
      end

      it 'handles SAVEPOINT operations' do
        expect(described_class.send(:extract_operation, 'SAVEPOINT foo')).to eq('savepoint')
        expect(described_class.send(:extract_operation, 'RELEASE SAVEPOINT foo')).to eq('savepoint.release')
        expect(described_class.send(:extract_operation, 'ROLLBACK TO SAVEPOINT foo')).to eq('savepoint.rollback')
      end

      it 'returns query for unknown operations' do
        result = described_class.send(:extract_operation, 'VACUUM ANALYZE')
        expect(result).to eq('query')
      end
    end

    describe '.extract_table_from_sql' do
      it 'extracts table from simple SELECT' do
        result = described_class.send(:extract_table_from_sql, 'SELECT * FROM users')
        expect(result).to eq('users')
      end

      it 'extracts table from quoted table names' do
        result = described_class.send(:extract_table_from_sql, 'SELECT * FROM "users"')
        expect(result).to eq('users')
      end

      it 'returns nil for non-SELECT queries' do
        result = described_class.send(:extract_table_from_sql, 'INSERT INTO users VALUES (1)')
        expect(result).to be_nil
      end
    end

    describe '.truncate_sql' do
      it 'truncates long SQL statements' do
        long_sql = 'SELECT ' + ('a' * 600)
        result = described_class.send(:truncate_sql, long_sql, 100)
        expect(result.length).to eq(100)
        expect(result).to end_with('...')
      end

      it 'normalizes whitespace' do
        sql = "SELECT *\n  FROM   users\n  WHERE id = 1"
        result = described_class.send(:truncate_sql, sql)
        expect(result).to eq('SELECT * FROM users WHERE id = 1')
      end

      it 'returns nil for nil input' do
        result = described_class.send(:truncate_sql, nil)
        expect(result).to be_nil
      end
    end
  end
end
