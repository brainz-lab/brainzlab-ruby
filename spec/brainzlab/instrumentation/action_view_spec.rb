# frozen_string_literal: true

require 'spec_helper'
require 'brainzlab/instrumentation/action_view'

# Mock ActionView for testing
module ActionView; end

RSpec.describe BrainzLab::Instrumentation::ActionView do
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

  describe '.install!' do
    it 'subscribes to ActionView events' do
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['render_template.action_view']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['render_partial.action_view']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['render_collection.action_view']).not_to be_empty
      expect(ActiveSupport::Notifications.subscribers['render_layout.action_view']).not_to be_empty
    end

    it 'is idempotent' do
      described_class.install!
      count = ActiveSupport::Notifications.subscribers['render_template.action_view'].size
      described_class.install!

      expect(ActiveSupport::Notifications.subscribers['render_template.action_view'].size).to eq(count)
    end

    it 'reports installed status' do
      expect(described_class.installed?).to be false
      described_class.install!
      expect(described_class.installed?).to be true
    end
  end

  describe 'render_template.action_view instrumentation' do
    before { described_class.install! }

    def emit_render_template(identifier:, layout: nil, duration_seconds: 0.02)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        identifier: identifier,
        layout: layout
      }

      ActiveSupport::Notifications.publish(
        'render_template.action_view',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    context 'breadcrumbs' do
      it 'adds breadcrumb for template renders' do
        emit_render_template(identifier: '/app/views/users/show.html.erb')

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        template_crumb = crumbs.find { |c| c[:category] == 'view.template' }

        expect(template_crumb).not_to be_nil
        expect(template_crumb[:message]).to include('users/show')
        expect(template_crumb[:level]).to eq('info')
      end

      it 'includes layout information' do
        emit_render_template(
          identifier: '/app/views/users/show.html.erb',
          layout: 'layouts/application'
        )

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        template_crumb = crumbs.find { |c| c[:category] == 'view.template' }

        expect(template_crumb[:data][:layout]).to eq('layouts/application')
      end

      it 'sets warning level for slow renders' do
        emit_render_template(identifier: '/app/views/users/show.html.erb', duration_seconds: 0.08)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        template_crumb = crumbs.find { |c| c[:category] == 'view.template' }

        expect(template_crumb[:level]).to eq('warning')
      end

      it 'sets error level for very slow renders' do
        emit_render_template(identifier: '/app/views/users/show.html.erb', duration_seconds: 0.25)

        crumbs = BrainzLab::Context.current.breadcrumbs.to_a
        template_crumb = crumbs.find { |c| c[:category] == 'view.template' }

        expect(template_crumb[:level]).to eq('error')
      end
    end

    context 'Pulse spans' do
      it 'adds span when trace is active' do
        BrainzLab::Pulse.start_trace('test.request', kind: 'request')

        emit_render_template(identifier: '/app/views/users/show.html.erb')

        tracer = BrainzLab::Pulse.tracer
        spans = tracer.current_spans

        view_span = spans.find { |s| s[:name].start_with?('view.template') }
        expect(view_span).not_to be_nil
        expect(view_span[:kind]).to eq('view')
        expect(view_span[:data]['view.type']).to eq('template')

        BrainzLab::Pulse.finish_trace
      end
    end
  end

  describe 'render_partial.action_view instrumentation' do
    before { described_class.install! }

    def emit_render_partial(identifier:, duration_seconds: 0.005, cache_hit: false)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        identifier: identifier,
        cache_hit: cache_hit
      }

      ActiveSupport::Notifications.publish(
        'render_partial.action_view',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for partial renders' do
      emit_render_partial(identifier: '/app/views/users/_user.html.erb', duration_seconds: 0.01)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      partial_crumb = crumbs.find { |c| c[:category] == 'view.partial' }

      expect(partial_crumb).not_to be_nil
      expect(partial_crumb[:message]).to include('users/_user')
    end

    it 'marks cached partials' do
      emit_render_partial(
        identifier: '/app/views/users/_user.html.erb',
        duration_seconds: 0.01,
        cache_hit: true
      )

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      partial_crumb = crumbs.find { |c| c[:category] == 'view.partial' }

      expect(partial_crumb[:message]).to include('cached')
      expect(partial_crumb[:data][:cached]).to be true
    end

    it 'skips very fast partials without cache hit' do
      emit_render_partial(identifier: '/app/views/users/_user.html.erb', duration_seconds: 0.0005)

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      partial_crumb = crumbs.find { |c| c[:category] == 'view.partial' }

      expect(partial_crumb).to be_nil
    end
  end

  describe 'render_collection.action_view instrumentation' do
    before { described_class.install! }

    def emit_render_collection(identifier:, count:, cache_hits: 0, duration_seconds: 0.05)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = {
        identifier: identifier,
        count: count,
        cache_hits: cache_hits
      }

      ActiveSupport::Notifications.publish(
        'render_collection.action_view',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds breadcrumb for large collections' do
      emit_render_collection(
        identifier: '/app/views/users/_user.html.erb',
        count: 25,
        duration_seconds: 0.1
      )

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      collection_crumb = crumbs.find { |c| c[:category] == 'view.collection' }

      expect(collection_crumb).not_to be_nil
      expect(collection_crumb[:message]).to include('x25')
      expect(collection_crumb[:data][:count]).to eq(25)
    end

    it 'includes cache hit information' do
      emit_render_collection(
        identifier: '/app/views/users/_user.html.erb',
        count: 20,
        cache_hits: 15,
        duration_seconds: 0.05
      )

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      collection_crumb = crumbs.find { |c| c[:category] == 'view.collection' }

      expect(collection_crumb[:message]).to include('15/20 cached')
      expect(collection_crumb[:data][:cache_hits]).to eq(15)
    end

    it 'calculates average time per item' do
      emit_render_collection(
        identifier: '/app/views/users/_user.html.erb',
        count: 10,
        duration_seconds: 0.1
      )

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      collection_crumb = crumbs.find { |c| c[:category] == 'view.collection' }

      expect(collection_crumb[:data][:avg_per_item_ms]).to eq(10.0)
    end

    it 'adds Pulse span for collections' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_render_collection(
        identifier: '/app/views/users/_user.html.erb',
        count: 20
      )

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      collection_span = spans.find { |s| s[:name].start_with?('view.collection') }
      expect(collection_span).not_to be_nil
      expect(collection_span[:data]['view.count']).to eq(20)

      BrainzLab::Pulse.finish_trace
    end

    it 'detects slow collection items' do
      emit_render_collection(
        identifier: '/app/views/users/_user.html.erb',
        count: 50,
        duration_seconds: 0.5 # 10ms per item - above threshold
      )

      crumbs = BrainzLab::Context.current.breadcrumbs.to_a
      performance_crumb = crumbs.find { |c| c[:category] == 'view.performance' }

      expect(performance_crumb).not_to be_nil
      expect(performance_crumb[:level]).to eq('warning')
      expect(performance_crumb[:data][:suggestion]).to include('caching')
    end
  end

  describe 'render_layout.action_view instrumentation' do
    before { described_class.install! }

    def emit_render_layout(identifier:, duration_seconds: 0.01)
      start_time = Time.now
      end_time = start_time + duration_seconds
      payload = { identifier: identifier }

      ActiveSupport::Notifications.publish(
        'render_layout.action_view',
        start_time,
        end_time,
        SecureRandom.hex(8),
        payload
      )
    end

    it 'adds Pulse span for layout renders' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_render_layout(identifier: '/app/views/layouts/application.html.erb')

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      layout_span = spans.find { |s| s[:name].start_with?('view.layout') }
      expect(layout_span).not_to be_nil
      expect(layout_span[:kind]).to eq('view')
      expect(layout_span[:data]['view.type']).to eq('layout')

      BrainzLab::Pulse.finish_trace
    end

    it 'skips very fast layout renders' do
      BrainzLab::Pulse.start_trace('test.request', kind: 'request')

      emit_render_layout(identifier: '/app/views/layouts/application.html.erb', duration_seconds: 0.002)

      tracer = BrainzLab::Pulse.tracer
      spans = tracer.current_spans

      layout_span = spans.find { |s| s[:name]&.start_with?('view.layout') }
      expect(layout_span).to be_nil

      BrainzLab::Pulse.finish_trace
    end
  end

  describe 'helper methods' do
    describe '.extract_template_name' do
      it 'extracts template name from full path' do
        result = described_class.send(:extract_template_name, '/app/views/users/show.html.erb')
        expect(result).to eq('users/show')
      end

      it 'extracts partial name' do
        result = described_class.send(:extract_template_name, '/app/views/users/_user.html.erb')
        expect(result).to eq('users/_user')
      end

      it 'handles paths without app/views' do
        result = described_class.send(:extract_template_name, '/some/other/path/template.html.erb')
        expect(result).to eq('template')
      end

      it 'handles nil' do
        result = described_class.send(:extract_template_name, nil)
        expect(result).to eq('unknown')
      end

      it 'removes multiple extensions' do
        result = described_class.send(:extract_template_name, '/app/views/users/show.json.jbuilder')
        expect(result).to eq('users/show')
      end
    end
  end
end
