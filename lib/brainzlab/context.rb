# frozen_string_literal: true

module BrainzLab
  class Context
    THREAD_KEY = :brainzlab_context

    class << self
      def current
        Thread.current[THREAD_KEY] ||= new
      end

      def clear!
        Thread.current[THREAD_KEY] = nil
      end
    end

    attr_accessor :user, :request_id, :session_id, :request_method, :request_path, :request_url, :request_params,
                  :request_headers, :controller, :action
    attr_reader :extra, :tags, :breadcrumbs

    def initialize
      @user = {}
      @extra = {}
      @tags = {}
      @request_id = nil
      @session_id = nil
      @request_method = nil
      @request_path = nil
      @request_url = nil
      @request_params = nil
      @request_headers = nil
      @controller = nil
      @action = nil
      @stack = []
      @breadcrumbs = Reflex::Breadcrumbs.new
    end

    def set_user(id: nil, email: nil, name: nil, **extra)
      @user = { id: id, email: email, name: name }.compact.merge(extra)
    end

    def set_context(**data)
      @extra.merge!(data)
    end

    def set_tags(**data)
      @tags.merge!(data)
    end

    def with_context(**data)
      push_context(data)
      yield
    ensure
      pop_context
    end

    def to_hash
      result = {}
      result[:request_id] = @request_id if @request_id
      result[:session_id] = @session_id if @session_id

      merged_extra = @extra.dup
      @stack.each { |ctx| merged_extra.merge!(ctx) }

      result[:user] = @user unless @user.empty?
      result[:tags] = @tags unless @tags.empty?
      result[:context] = merged_extra unless merged_extra.empty?

      result
    end

    def data_hash
      merged = @extra.dup
      @stack.each { |ctx| merged.merge!(ctx) }
      merged[:user] = @user unless @user.empty?
      merged[:tags] = @tags unless @tags.empty?
      merged
    end

    private

    def push_context(data)
      @stack.push(data)
    end

    def pop_context
      @stack.pop
    end
  end
end
