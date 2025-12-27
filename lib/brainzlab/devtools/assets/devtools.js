/**
 * BrainzLab DevTools - Debug Panel Interactivity
 */
(function() {
  'use strict';

  const BrainzDevTools = {
    panel: null,

    init() {
      this.panel = document.querySelector('.brainz-debug-panel');
      if (!this.panel) return;

      this.bindEvents();
      this.loadState();
    },

    bindEvents() {
      // Toggle panel on toolbar click
      const toolbar = this.panel.querySelector('.brainz-debug-toolbar');
      if (toolbar) {
        toolbar.addEventListener('click', (e) => {
          // Don't toggle if clicking on a stat that might have a link
          if (e.target.closest('.brainz-debug-stat a')) return;
          this.togglePanel();
        });
      }

      // Tab switching
      const tabs = this.panel.querySelectorAll('.brainz-debug-tab');
      tabs.forEach(tab => {
        tab.addEventListener('click', (e) => {
          e.stopPropagation();
          this.switchTab(tab.dataset.tab);
        });
      });

      // Expandable SQL queries
      const queryRows = this.panel.querySelectorAll('.brainz-query-row');
      queryRows.forEach(row => {
        row.style.cursor = 'pointer';
        row.addEventListener('click', () => this.toggleQueryDetails(row));
      });

      // Keyboard shortcuts
      document.addEventListener('keydown', (e) => {
        // Ctrl/Cmd + Shift + B to toggle panel
        if ((e.ctrlKey || e.metaKey) && e.shiftKey && e.key === 'B') {
          e.preventDefault();
          this.togglePanel();
        }
        // Escape to collapse panel
        if (e.key === 'Escape' && !this.panel.classList.contains('collapsed')) {
          this.togglePanel();
        }
      });

      // Copy SQL query on double-click
      const sqlCells = this.panel.querySelectorAll('.brainz-query-sql');
      sqlCells.forEach(cell => {
        cell.addEventListener('dblclick', () => {
          const sql = cell.getAttribute('title') || cell.textContent;
          this.copyToClipboard(sql);
          this.showToast('SQL copied to clipboard');
        });
      });
    },

    togglePanel() {
      this.panel.classList.toggle('collapsed');
      this.saveState();
    },

    switchTab(tabName) {
      // Update tab buttons
      this.panel.querySelectorAll('.brainz-debug-tab').forEach(t => {
        t.classList.toggle('active', t.dataset.tab === tabName);
      });

      // Update content panes
      this.panel.querySelectorAll('.brainz-debug-pane').forEach(p => {
        p.classList.toggle('active', p.dataset.pane === tabName);
      });

      this.saveState();
    },

    toggleQueryDetails(row) {
      const details = row.nextElementSibling;
      if (details && details.classList.contains('brainz-query-details')) {
        details.classList.toggle('expanded');
        row.classList.toggle('expanded');
      }
    },

    copyToClipboard(text) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text);
      } else {
        // Fallback for older browsers
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.style.position = 'fixed';
        textarea.style.opacity = '0';
        document.body.appendChild(textarea);
        textarea.select();
        document.execCommand('copy');
        document.body.removeChild(textarea);
      }
    },

    showToast(message) {
      // Create toast element
      const toast = document.createElement('div');
      toast.style.cssText = `
        position: fixed;
        bottom: 60px;
        right: 20px;
        padding: 8px 16px;
        background: #1A202C;
        color: white;
        border-radius: 6px;
        font-size: 13px;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        z-index: 1000000;
        opacity: 0;
        transition: opacity 0.2s ease;
      `;
      toast.textContent = message;
      document.body.appendChild(toast);

      // Animate in
      requestAnimationFrame(() => {
        toast.style.opacity = '1';
      });

      // Remove after delay
      setTimeout(() => {
        toast.style.opacity = '0';
        setTimeout(() => {
          document.body.removeChild(toast);
        }, 200);
      }, 2000);
    },

    saveState() {
      try {
        const state = {
          collapsed: this.panel.classList.contains('collapsed'),
          activeTab: this.panel.querySelector('.brainz-debug-tab.active')?.dataset.tab || 'request'
        };
        sessionStorage.setItem('brainz-devtools-state', JSON.stringify(state));
      } catch (e) {
        // Ignore storage errors
      }
    },

    loadState() {
      try {
        const stateStr = sessionStorage.getItem('brainz-devtools-state');
        if (stateStr) {
          const state = JSON.parse(stateStr);
          if (state.collapsed) {
            this.panel.classList.add('collapsed');
          }
          if (state.activeTab) {
            this.switchTab(state.activeTab);
          }
        }
      } catch (e) {
        // Ignore storage errors
      }
    }
  };

  // Initialize on DOM ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => BrainzDevTools.init());
  } else {
    BrainzDevTools.init();
  }

  // Expose for debugging
  window.BrainzDevTools = BrainzDevTools;
})();
