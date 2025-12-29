/**
 * BrainzLab DevTools - Stimulus Controller
 */
(function() {
  'use strict';

  // Load Stimulus if not available
  let stimulusApp = null;
  let StimulusController = null;

  async function loadStimulus() {
    if (stimulusApp) return { app: stimulusApp, Controller: StimulusController };

    // Check if already loading
    if (window._stimulusLoading) return window._stimulusLoading;

    window._stimulusLoading = new Promise((resolve) => {
      const script = document.createElement('script');
      script.src = 'https://unpkg.com/@hotwired/stimulus@3.2.2/dist/stimulus.umd.js';
      script.onload = () => {
        StimulusController = window.Stimulus.Controller;
        stimulusApp = window.Stimulus.Application.start();
        resolve({ app: stimulusApp, Controller: StimulusController });
      };
      document.head.appendChild(script);
    });

    return window._stimulusLoading;
  }

  // Stimulus Controller Definition
  const DevtoolsController = {
    static: {
      targets: ['panel', 'tab', 'pane', 'toast']
    },

    // Lifecycle
    connect() {
      this.loadState();
      this.bindKeyboardShortcuts();
    },

    disconnect() {
      this.unbindKeyboardShortcuts();
    },

    // Actions
    togglePanel() {
      this.element.classList.toggle('collapsed');
      this.saveState();
    },

    switchTab(event) {
      event.stopPropagation();
      const tabName = event.currentTarget.dataset.tab;

      // Update tab buttons
      this.element.querySelectorAll('[data-devtools-target="tab"]').forEach(t => {
        t.classList.toggle('active', t.dataset.tab === tabName);
      });

      // Update content panes
      this.element.querySelectorAll('[data-devtools-target="pane"]').forEach(p => {
        p.classList.toggle('active', p.dataset.pane === tabName);
      });

      this.saveState();
    },

    copyToAi(event) {
      event.stopPropagation();
      event.preventDefault();

      const button = event.currentTarget;
      const issueType = button.dataset.issueType;
      const prompt = this.buildPrompt(issueType, button);

      this.copyToClipboard(prompt);
      this.showToast('Copied to clipboard');

      // Visual feedback
      button.classList.add('copied');
      setTimeout(() => button.classList.remove('copied'), 1500);
    },

    copySql(event) {
      const cell = event.currentTarget;
      const sql = cell.getAttribute('title') || cell.textContent;
      this.copyToClipboard(sql);
      this.showToast('SQL copied');
    },

    // Prompt Builders
    buildPrompt(issueType, button) {
      const builders = {
        n_plus_one: () => this.buildN1Prompt(button),
        slow_query: () => this.buildSlowQueryPrompt(button),
        too_many_queries: () => this.buildTooManyQueriesPrompt(button),
        slow_view: () => this.buildSlowViewPrompt(button),
        high_memory: () => this.buildHighMemoryPrompt(button)
      };

      return builders[issueType]?.() || 'Unknown issue type';
    },

    buildN1Prompt(btn) {
      const { n1Count, n1Duration, n1Source, n1Query, n1Pattern } = btn.dataset;
      return `Fix this N+1 query issue in my Rails application:

## Problem
Detected ${n1Count || 'unknown'}x similar queries (${n1Duration || 'unknown'}ms total) from:
\`${n1Source || 'unknown location'}\`

## Sample Query
\`\`\`sql
${n1Query || ''}
\`\`\`

## Pattern
\`\`\`
${n1Pattern || ''}
\`\`\`

## Instructions
1. Find the source code at the location mentioned above
2. Identify why this query is being executed multiple times
3. Suggest a fix using eager loading (includes/preload/eager_load) or other optimization
4. Show me the before and after code`;
    },

    buildSlowQueryPrompt(btn) {
      const { queryDuration, querySql, querySource, queryName } = btn.dataset;
      return `Optimize this slow database query in my Rails application:

## Problem
Query taking ${queryDuration || 'unknown'}ms (threshold: 100ms)
Source: \`${querySource || 'unknown location'}\`
Name: ${queryName || 'SQL'}

## Query
\`\`\`sql
${querySql || ''}
\`\`\`

## Instructions
1. Analyze why this query might be slow
2. Check if there are missing database indexes
3. Suggest query optimizations or restructuring
4. If applicable, suggest caching strategies
5. Show me the recommended changes`;
    },

    buildTooManyQueriesPrompt(btn) {
      const { queryCount, controllerName, actionName } = btn.dataset;
      return `Reduce the number of database queries in my Rails application:

## Problem
${queryCount || 'unknown'} queries executed in a single request (threshold: 20)
Controller: ${controllerName || 'unknown'}#${actionName || 'unknown'}

## Instructions
1. Look at the controller action and identify what data is being loaded
2. Find opportunities to use eager loading (includes/preload/eager_load)
3. Identify if any queries can be combined or eliminated
4. Check for queries inside loops (potential N+1)
5. Suggest caching for frequently accessed data
6. Show me the before and after code`;
    },

    buildSlowViewPrompt(btn) {
      const { viewDuration, viewTemplate, viewType } = btn.dataset;
      return `Optimize this slow view render in my Rails application:

## Problem
${viewType || 'template'} taking ${viewDuration || 'unknown'}ms to render (threshold: 50ms)
Template: ${viewTemplate || 'unknown'}

## Instructions
1. Look at the template and identify expensive operations
2. Check for complex logic that should be moved to helpers or presenters
3. Look for database queries being made in the view
4. Identify if fragment caching could help
5. Check for unnecessary partial renders or loops
6. Suggest optimizations and show me the recommended changes`;
    },

    buildHighMemoryPrompt(btn) {
      const { memoryDelta, memoryBefore, memoryAfter, controllerName, actionName } = btn.dataset;
      return `Investigate high memory usage in my Rails application:

## Problem
Request allocated +${memoryDelta || 'unknown'}MB of memory (threshold: 50MB)
Memory before: ${memoryBefore || 'unknown'}MB
Memory after: ${memoryAfter || 'unknown'}MB
Controller: ${controllerName || 'unknown'}#${actionName || 'unknown'}

## Instructions
1. Look at the controller action and identify what data is being loaded
2. Check for loading large datasets into memory (use find_each/find_in_batches)
3. Look for creating many objects in loops
4. Check if large files or blobs are being processed
5. Identify if streaming responses could help
6. Suggest memory optimizations and show me the recommended changes`;
    },

    // Utilities
    copyToClipboard(text) {
      if (navigator.clipboard?.writeText) {
        navigator.clipboard.writeText(text);
      } else {
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.style.cssText = 'position:fixed;opacity:0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
      }
    },

    showToast(message) {
      // Remove existing toast
      const existing = document.querySelector('.brainz-toast');
      if (existing) existing.remove();

      const toast = document.createElement('div');
      toast.className = 'brainz-toast';
      toast.textContent = message;
      document.body.appendChild(toast);

      requestAnimationFrame(() => toast.classList.add('visible'));

      setTimeout(() => {
        toast.classList.remove('visible');
        setTimeout(() => toast.remove(), 200);
      }, 2000);
    },

    // State Management
    saveState() {
      try {
        const activeTab = this.element.querySelector('[data-devtools-target="tab"].active');
        sessionStorage.setItem('brainz-devtools-state', JSON.stringify({
          collapsed: this.element.classList.contains('collapsed'),
          activeTab: activeTab?.dataset.tab || 'request'
        }));
      } catch (e) { /* ignore */ }
    },

    loadState() {
      try {
        const state = JSON.parse(sessionStorage.getItem('brainz-devtools-state'));
        if (state?.collapsed) this.element.classList.add('collapsed');
        if (state?.activeTab) {
          const tab = this.element.querySelector(`[data-tab="${state.activeTab}"]`);
          if (tab) tab.click();
        }
      } catch (e) { /* ignore */ }
    },

    // Keyboard Shortcuts
    bindKeyboardShortcuts() {
      this._keyHandler = (e) => {
        if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === 'B') {
          e.preventDefault();
          this.togglePanel();
        }
        if (e.key === 'Escape' && !this.element.classList.contains('collapsed')) {
          this.togglePanel();
        }
      };
      document.addEventListener('keydown', this._keyHandler);
    },

    unbindKeyboardShortcuts() {
      if (this._keyHandler) {
        document.removeEventListener('keydown', this._keyHandler);
      }
    }
  };

  // Register Stimulus controller
  async function initialize() {
    const panel = document.querySelector('.brainz-debug-panel');
    if (!panel) return;

    // Load Stimulus and register controller
    const { app, Controller } = await loadStimulus();

    // Register the devtools controller
    app.register('devtools', class extends Controller {
      static targets = ['tab', 'pane'];

      connect() { DevtoolsController.connect.call(this); }
      disconnect() { DevtoolsController.disconnect.call(this); }
      togglePanel() { DevtoolsController.togglePanel.call(this); }
      switchTab(e) { DevtoolsController.switchTab.call(this, e); }
      copyToAi(e) { DevtoolsController.copyToAi.call(this, e); }
      copySql(e) { DevtoolsController.copySql.call(this, e); }

      buildPrompt(...args) { return DevtoolsController.buildPrompt.call(this, ...args); }
      buildN1Prompt(...args) { return DevtoolsController.buildN1Prompt.call(this, ...args); }
      buildSlowQueryPrompt(...args) { return DevtoolsController.buildSlowQueryPrompt.call(this, ...args); }
      buildTooManyQueriesPrompt(...args) { return DevtoolsController.buildTooManyQueriesPrompt.call(this, ...args); }
      buildSlowViewPrompt(...args) { return DevtoolsController.buildSlowViewPrompt.call(this, ...args); }
      buildHighMemoryPrompt(...args) { return DevtoolsController.buildHighMemoryPrompt.call(this, ...args); }
      copyToClipboard(...args) { return DevtoolsController.copyToClipboard.call(this, ...args); }
      showToast(...args) { return DevtoolsController.showToast.call(this, ...args); }
      saveState() { DevtoolsController.saveState.call(this); }
      loadState() { DevtoolsController.loadState.call(this); }
      bindKeyboardShortcuts() { DevtoolsController.bindKeyboardShortcuts.call(this); }
      unbindKeyboardShortcuts() { DevtoolsController.unbindKeyboardShortcuts.call(this); }
    });
  }

  // Initialize on DOM ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize);
  } else {
    initialize();
  }
})();
