# frozen_string_literal: true

require_relative 'dendrite/client'
require_relative 'dendrite/provisioner'

module BrainzLab
  module Dendrite
    class << self
      # Connect a Git repository for documentation
      # @param url [String] Git repository URL
      # @param name [String] Optional display name
      # @param branch [String] Branch to track (default: main)
      # @return [Hash, nil] Repository info
      #
      # @example
      #   BrainzLab::Dendrite.connect(
      #     "https://github.com/org/repo",
      #     name: "My API",
      #     branch: "main"
      #   )
      #
      def connect(url, name: nil, branch: 'main', **)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.dendrite_valid?

        client.connect_repository(url: url, name: name, branch: branch, **)
      end

      # Trigger documentation sync for a repository
      # @param repo_id [String] Repository ID
      # @return [Boolean] True if sync started
      def sync(repo_id)
        return false unless enabled?

        ensure_provisioned!
        return false unless BrainzLab.configuration.dendrite_valid?

        client.sync_repository(repo_id)
      end

      # Get repository info
      # @param repo_id [String] Repository ID
      # @return [Hash, nil] Repository details
      def repository(repo_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.dendrite_valid?

        client.get_repository(repo_id)
      end

      # List all connected repositories
      # @return [Array<Hash>] List of repositories
      def repositories
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.dendrite_valid?

        client.list_repositories
      end

      # Get wiki for a repository
      # @param repo_id [String] Repository ID
      # @return [Hash, nil] Wiki structure
      def wiki(repo_id)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.dendrite_valid?

        client.get_wiki(repo_id)
      end

      # Get a specific wiki page
      # @param repo_id [String] Repository ID
      # @param page [String] Page slug (e.g., "models/user")
      # @return [Hash, nil] Page content
      def page(repo_id, page_slug)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.dendrite_valid?

        client.get_wiki_page(repo_id, page_slug)
      end

      # Semantic search across the codebase
      # @param repo_id [String] Repository ID
      # @param query [String] Search query
      # @param limit [Integer] Max results (default: 10)
      # @return [Array<Hash>] Search results
      #
      # @example
      #   results = BrainzLab::Dendrite.search(repo_id, "authentication flow")
      #
      def search(repo_id, query, limit: 10)
        return [] unless enabled?

        ensure_provisioned!
        return [] unless BrainzLab.configuration.dendrite_valid?

        client.search(repo_id, query, limit: limit)
      end

      # Ask a question about the codebase
      # @param repo_id [String] Repository ID
      # @param question [String] Question to ask
      # @param session_id [String] Optional session for follow-up questions
      # @return [Hash, nil] AI response with answer
      #
      # @example
      #   response = BrainzLab::Dendrite.ask(repo_id, "How does the payment flow work?")
      #   puts response[:answer]
      #
      def ask(repo_id, question, session_id: nil)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.dendrite_valid?

        client.ask(repo_id, question, session_id: session_id)
      end

      # Explain a file or code symbol
      # @param repo_id [String] Repository ID
      # @param path [String] File path
      # @param symbol [String] Optional specific symbol (class, method)
      # @return [Hash, nil] Explanation
      #
      # @example
      #   explanation = BrainzLab::Dendrite.explain(repo_id, "app/models/user.rb", symbol: "authenticate")
      #
      def explain(repo_id, path, symbol: nil)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.dendrite_valid?

        client.explain(repo_id, path, symbol: symbol)
      end

      # Generate a diagram
      # @param repo_id [String] Repository ID
      # @param type [Symbol] Diagram type (:class, :er, :sequence, :architecture)
      # @param scope [String] Optional scope (module, class name)
      # @return [Hash, nil] Mermaid diagram
      #
      # @example
      #   diagram = BrainzLab::Dendrite.diagram(repo_id, :er)
      #   puts diagram[:mermaid]
      #
      def diagram(repo_id, type:, scope: nil)
        return nil unless enabled?

        ensure_provisioned!
        return nil unless BrainzLab.configuration.dendrite_valid?

        client.generate_diagram(repo_id, type: type, scope: scope)
      end

      # === INTERNAL ===

      def ensure_provisioned!
        return if @provisioned

        @provisioned = true
        provisioner.ensure_project!
      end

      def provisioner
        @provisioner ||= Provisioner.new(BrainzLab.configuration)
      end

      def client
        @client ||= Client.new(BrainzLab.configuration)
      end

      def reset!
        @client = nil
        @provisioner = nil
        @provisioned = false
      end

      private

      def enabled?
        BrainzLab.configuration.dendrite_enabled
      end
    end
  end
end
