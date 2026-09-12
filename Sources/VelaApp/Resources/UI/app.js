/**
 * Vela Desktop Workspace Client
 * Fully contract-compliant, zero-dependency, local-first UI engine
 * Reflecting authoritative backend schemas, safe lifecycle transitions, and strict XSS escaping
 */

(function() {
  'use strict';

  // Application State
  const state = {
    currentPage: 'agents',
    currentProject: '',
    priorProject: '',
    dashboard: null,
    dashboardScope: null,
    scopeError: null,
    registeredProjects: [],
    selectedSessionId: null,
    selectedRunId: null,
    selectedSuggestionId: null,
    selectedEvalId: null,
    setupActiveTab: 'rules',
    workflowsActiveTab: 'list',
    labActiveTab: 'evals',
    pollTimer: null,
    isBridgeAvailable: false,
    isDemoMode: false,
    rawSettings: {},
    systemInfo: {
      channel: 'dev',
      home: '~/.vela-dev',
      version: '0.1.0'
    },
    // Filter persistence
    sessionFilterQuery: '',
    sessionProviderFilter: '',
    sessionStatusFilter: '',
    memoryFilter: 'all',
    // Settings draft, snapshot cache, and live session tracking
    settingsDraft: null,
    lastRenderedSnapshotJson: null,
    hasPendingSnapshot: false,
    loadedSessionDetail: null
  };

  // Utilities & Strict HTML Escaping
  function escapeHtml(str) {
    if (str === null || str === undefined) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  // Safe i18n bridges
  const t = (key, params) => (window.VelaI18n ? window.VelaI18n.t(key, params) : key);
  const tHtml = (key, params, tag) => (window.VelaI18n ? window.VelaI18n.tHtml(key, params, tag) : escapeHtml(key));

  function formatTime(isoStr) {
    if (!isoStr) return '-';
    try {
      const d = new Date(isoStr);
      if (isNaN(d.getTime())) return '-';
      const loc = (window.VelaI18n && window.VelaI18n.getLocale() === 'en') ? 'en-US' : 'zh-CN';
      return d.toLocaleString(loc, {
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
      });
    } catch {
      return '-';
    }
  }

  function formatNumber(num) {
    if (window.VelaI18n && typeof window.VelaI18n.formatNumber === 'function') {
      return window.VelaI18n.formatNumber(num);
    }
    if (typeof num !== 'number' || !Number.isFinite(num)) return '-';
    return num.toLocaleString();
  }

  function formatProviderName(provider) {
    if (!provider) return t('provider.unknown');
    const p = String(provider).toLowerCase();
    if (p === 'claude' || p === 'claude-code') return 'Claude Code';
    if (p === 'codex') return 'Codex';
    if (p === 'cursor') return 'Cursor';
    if (p === 'copilot') return 'GitHub Copilot';
    return provider;
  }

  function formatMemoryType(tVal) {
    const map = {
      fact: 'memory.typeFact',
      decision: 'memory.typeDecision',
      constraint: 'memory.typeConstraint',
      preference: 'memory.typePreference',
      failure: 'memory.typeFailure',
      'workflow knowledge': 'memory.typeWorkflowKnowledge',
      observation: 'memory.typeObservation',
      hypothesis: 'memory.typeHypothesis',
      checkpoint: 'memory.typeCheckpoint'
    };
    const key = map[(tVal || '').toLowerCase()];
    return key ? t(key) : (tVal || t('memory.typeFact'));
  }

  function renderMemoryTypeBadge(tVal) {
    const map = {
      fact: 'memory.typeFact',
      decision: 'memory.typeDecision',
      constraint: 'memory.typeConstraint',
      preference: 'memory.typePreference',
      failure: 'memory.typeFailure',
      'workflow knowledge': 'memory.typeWorkflowKnowledge',
      observation: 'memory.typeObservation',
      hypothesis: 'memory.typeHypothesis',
      checkpoint: 'memory.typeCheckpoint'
    };
    const key = map[(tVal || '').toLowerCase()];
    if (key) {
      return `<span class="memory-type-badge" data-i18n="${key}">${escapeHtml(t(key))}</span>`;
    }
    return `<span class="memory-type-badge">${escapeHtml(tVal || t('memory.typeFact'))}</span>`;
  }

  function renderMemoryTypeInline(tVal) {
    const map = {
      fact: 'memory.typeFact',
      decision: 'memory.typeDecision',
      constraint: 'memory.typeConstraint',
      preference: 'memory.typePreference',
      failure: 'memory.typeFailure',
      'workflow knowledge': 'memory.typeWorkflowKnowledge',
      observation: 'memory.typeObservation',
      hypothesis: 'memory.typeHypothesis',
      checkpoint: 'memory.typeCheckpoint'
    };
    const key = map[(tVal || '').toLowerCase()];
    if (key) {
      return `<span data-i18n="${key}">${escapeHtml(t(key))}</span>`;
    }
    return `<span>${escapeHtml(tVal || t('memory.typeFact'))}</span>`;
  }

  function formatMemoryScope(s) {
    const map = {
      project: 'memory.scopeProject',
      global: 'memory.scopeGlobal',
      branch: 'memory.scopeBranch',
      worktree: 'memory.scopeWorktree'
    };
    const key = map[(s || '').toLowerCase()];
    return key ? t(key) : (s || t('memory.scopeProject'));
  }

  function renderMemoryScopeBadge(s) {
    const map = {
      project: 'memory.scopeProject',
      global: 'memory.scopeGlobal',
      branch: 'memory.scopeBranch',
      worktree: 'memory.scopeWorktree'
    };
    const key = map[(s || '').toLowerCase()];
    if (key) {
      return `<span class="memory-type-badge" data-i18n="${key}">${escapeHtml(t(key))}</span>`;
    }
    return `<span class="memory-type-badge">${escapeHtml(s || t('memory.scopeProject'))}</span>`;
  }

  function renderMemoryScopeInline(s) {
    const map = {
      project: 'memory.scopeProject',
      global: 'memory.scopeGlobal',
      branch: 'memory.scopeBranch',
      worktree: 'memory.scopeWorktree'
    };
    const key = map[(s || '').toLowerCase()];
    if (key) {
      return `<span data-i18n="${key}">${escapeHtml(t(key))}</span>`;
    }
    return `<span>${escapeHtml(s || t('memory.scopeProject'))}</span>`;
  }

  function formatDiscoveryKind(kind) {
    if (!kind) return '';
    const k = String(kind).toLowerCase();
    if (k === 'tool-sequence') return t('improve.kindToolSequence');
    if (k === 'frequency') return t('improve.kindFrequency');
    if (k === 'rule-conflict') return t('improve.kindRuleConflict');
    if (k === 'error-pattern') return t('improve.kindErrorPattern');
    return '';
  }

  function renderDiscoveryKindBadge(kind) {
    if (!kind) return '';
    const k = String(kind).toLowerCase();
    const map = {
      'tool-sequence': 'improve.kindToolSequence',
      'frequency': 'improve.kindFrequency',
      'rule-conflict': 'improve.kindRuleConflict',
      'error-pattern': 'improve.kindErrorPattern'
    };
    const key = map[k];
    if (key) {
      return `<span class="badge-subtle" data-i18n="${key}">${escapeHtml(t(key))}</span>`;
    }
    return `<span class="badge-subtle">${escapeHtml(kind)}</span>`;
  }

  function renderDiscoveryKindInline(kind) {
    if (!kind) return '';
    const k = String(kind).toLowerCase();
    const map = {
      'tool-sequence': 'improve.kindToolSequence',
      'frequency': 'improve.kindFrequency',
      'rule-conflict': 'improve.kindRuleConflict',
      'error-pattern': 'improve.kindErrorPattern'
    };
    const key = map[k];
    if (key) {
      return `<span class="font-mono" data-i18n="${key}">${escapeHtml(t(key))}</span>`;
    }
    return `<span class="font-mono">${escapeHtml(kind)}</span>`;
  }

  function setElementDescriptor(el, descriptorOrText) {
    if (!el) return;
    if (window.VelaI18n && typeof window.VelaI18n.setElementDescriptor === 'function') {
      window.VelaI18n.setElementDescriptor(el, descriptorOrText);
      return;
    }
    if (descriptorOrText && typeof descriptorOrText === 'object' && descriptorOrText.key) {
      el.setAttribute('data-i18n', descriptorOrText.key);
      if (descriptorOrText.params) {
        el.setAttribute('data-i18n-params', JSON.stringify(descriptorOrText.params));
      } else {
        el.removeAttribute('data-i18n-params');
      }
      el.textContent = t(descriptorOrText.key, descriptorOrText.params);
    } else {
      el.removeAttribute('data-i18n');
      el.removeAttribute('data-i18n-params');
      el.textContent = (descriptorOrText !== null && descriptorOrText !== undefined) ? String(descriptorOrText) : '';
    }
  }

  function showToast(messageOrDescriptor, type = 'info') {
    const container = document.getElementById('toast-container');
    if (!container) return;
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    setElementDescriptor(toast, messageOrDescriptor);
    container.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transform = 'translateY(8px)';
      setTimeout(() => toast.remove(), 200);
    }, 3200);
  }

  // Local Status Footer Management
  function updateFooterStatus(statusState, message) {
    const footer = document.getElementById('local-status');
    if (!footer) return;
    footer.dataset.state = statusState;
    const textEl = footer.querySelector('.status-text');
    if (textEl) {
      if (message) {
        setElementDescriptor(textEl, message);
      } else if (statusState === 'connected') {
        const key = state.isDemoMode ? 'shell.statusDemo' : 'shell.statusConnected';
        setElementDescriptor(textEl, { key });
      } else if (statusState === 'loading') {
        setElementDescriptor(textEl, { key: 'shell.statusConnecting' });
      } else if (statusState === 'error') {
        setElementDescriptor(textEl, { key: 'shell.statusDisconnected' });
      }
    }
  }

  // Hook native __velaRejectAll to update footer status immediately on helper disconnect/overflow
  if (typeof window !== 'undefined') {
    const origRejectAll = window.__velaRejectAll;
    window.__velaRejectAll = function(reason) {
      if (typeof origRejectAll === 'function') {
        try {
          origRejectAll(reason);
        } catch {}
      }
      updateFooterStatus('error', reason || { key: 'shell.statusDisconnectedReason' });
    };
  }

  // Bridge Gateway
  async function callBridge(method, params = {}) {
    if (window.vela && typeof window.vela.call === 'function') {
      return window.vela.call(method, params);
    }
    if (state.isDemoMode && window.VelaDemo && typeof window.VelaDemo.handleCall === 'function') {
      return window.VelaDemo.handleCall(method, params);
    }
    throw new Error('本地 Vela 服务未连接');
  }

  // Initialization
  async function init() {
    updateFooterStatus('loading');
    setupShortcuts();
    setupEventListeners();

    if (window.vela && typeof window.vela.call === 'function') {
      state.isBridgeAvailable = true;
      try {
        const initSettings = await callBridge('settings.get');
        if (initSettings) {
          state.rawSettings = initSettings;
          if (initSettings.locale === 'en' || initSettings.locale === 'zh-CN') {
            if (window.VelaI18n && window.VelaI18n.getLocale() !== initSettings.locale) {
              window.VelaI18n.setLocale(initSettings.locale);
            }
          }
        }
      } catch {}
    } else {
      // Browser preview mode ONLY
      state.isDemoMode = true;
      const banner = document.getElementById('demo-banner');
      if (banner) banner.classList.remove('hidden');
      await loadDemoScript();
    }

    // First load dashboard data and perform initial render
    await refreshDashboard(true, true);

    if (state.isBridgeAvailable) {
      try {
        const info = await callBridge('system.info');
        if (info) {
          state.systemInfo = info;
          updateSystemInfoDisplay();
        }
      } catch {}

      // Move system.ready until AFTER first completed refreshDashboard and render
      // to prevent pending notification routes from being overwritten by initial state load
      try {
        await callBridge('system.ready');
      } catch (err) {
        console.warn('system.ready returned error:', err);
      }
    }

    setupPolling();
  }

  function updateSystemInfoDisplay() {
    const badge = document.getElementById('channel-badge');
    const pathDisp = document.getElementById('store-path-display');
    if (badge) badge.textContent = state.systemInfo.channel || 'dev';
    if (pathDisp) pathDisp.textContent = state.systemInfo.home || '~/.vela-dev';
  }

  function loadDemoScript() {
    return new Promise((resolve) => {
      const script = document.createElement('script');
      script.src = 'demo.js';
      script.onload = () => {
        if (window.VelaDemo) window.VelaDemo.init();
        resolve();
      };
      script.onerror = () => {
        console.error('Failed to load demo.js fixture');
        resolve();
      };
      document.head.appendChild(script);
    });
  }

  let activeRefreshPromise = null;
  let queuedRefreshResolvers = [];
  let refreshEpoch = 0;
  let renderGeneration = 0;
  let hasQueuedRefresh = false;
  let queuedForceRedraw = false;
  let queuedShowErrorBanner = false;

  function renderInitialRetryView(err) {
    const container = document.getElementById('page-container');
    if (!container) return;
    const hasErrMsg = err && err.message;
    container.innerHTML = `
      <div class="empty-state" style="padding-top: 100px;">
        <div class="empty-state-title" data-i18n="shell.initialRetryTitle" style="color: var(--status-red); font-size: 14px;">${escapeHtml(t('shell.initialRetryTitle'))}</div>
        <div class="empty-state-desc" ${!hasErrMsg ? 'data-i18n="shell.initialRetryDefaultDesc"' : ''} style="font-size: 12px; color: var(--text-secondary); max-width: 440px; margin: 8px auto;">
          ${escapeHtml(hasErrMsg ? err.message : t('shell.initialRetryDefaultDesc'))}
        </div>
        <button id="btn-init-retry" class="btn btn-primary btn-sm" data-i18n="shell.btnRetryConnect" style="margin-top: 14px;">${escapeHtml(t('shell.btnRetryConnect'))}</button>
      </div>
    `;
    const btnRetry = document.getElementById('btn-init-retry');
    if (btnRetry) {
      btnRetry.addEventListener('click', () => refreshDashboard(true, true));
    }
  }

  function renderScopeErrorView(container) {
    if (!container) return;
    const targetProject = state.currentProject;
    const targetLabel = targetProject ? (targetProject.split('/').filter(Boolean).pop() || targetProject) : '';
    const customErrMsg = (state.scopeError && state.scopeError.project === targetProject && state.scopeError.message)
      ? state.scopeError.message
      : null;
    const priorProject = state.scopeError ? state.scopeError.priorProject : (state.priorProject || '');

    const titleAttr = targetLabel
      ? `data-i18n="shell.scopeErrorTitle" data-i18n-params="${escapeHtml(JSON.stringify({ project: targetLabel }))}"`
      : `data-i18n="shell.scopeErrorGlobalTitle"`;
    const titleText = targetLabel
      ? t('shell.scopeErrorTitle', { project: targetLabel })
      : t('shell.scopeErrorGlobalTitle');

    const descHtml = customErrMsg
      ? `<span>${escapeHtml(customErrMsg)}</span><span data-i18n="shell.scopeErrorNotice">${escapeHtml(t('shell.scopeErrorNotice'))}</span>`
      : `<span data-i18n="shell.scopeErrorDefaultDesc">${escapeHtml(t('shell.scopeErrorDefaultDesc'))}</span><span data-i18n="shell.scopeErrorNotice">${escapeHtml(t('shell.scopeErrorNotice'))}</span>`;

    container.innerHTML = `
      <div class="empty-state" style="padding: 60px 24px;">
        <div class="empty-state-title" ${titleAttr} style="color: var(--status-red, #dc2626); font-size: 15px;">
          ${escapeHtml(titleText)}
        </div>
        <div class="empty-state-desc" style="font-size: 12px; color: var(--text-secondary); max-width: 480px; margin: 8px auto 16px;">
          ${descHtml}
        </div>
        <div style="display: flex; gap: 10px; justify-content: center; flex-wrap: wrap;">
          <button id="btn-retry-scope" class="btn btn-primary btn-sm" data-i18n="shell.btnRetryLoad">${escapeHtml(t('shell.btnRetryLoad'))}</button>
          ${priorProject !== undefined && priorProject !== null && priorProject !== targetProject ? `
            <button id="btn-revert-scope" class="btn btn-secondary btn-sm" data-i18n="shell.btnRevertScope">${escapeHtml(t('shell.btnRevertScope'))}</button>
          ` : `
            <button id="btn-revert-global-scope" class="btn btn-secondary btn-sm" data-i18n="shell.btnRevertGlobalScope">${escapeHtml(t('shell.btnRevertGlobalScope'))}</button>
          `}
        </div>
      </div>
    `;

    document.getElementById('btn-retry-scope')?.addEventListener('click', () => {
      refreshDashboard(true, true);
    });

    document.getElementById('btn-revert-scope')?.addEventListener('click', () => {
      const revertTarget = priorProject || '';
      state.currentProject = revertTarget;
      const projSel = document.getElementById('project-selector');
      if (projSel) projSel.value = revertTarget;
      state.scopeError = null;
      refreshDashboard(true, true);
    });

    document.getElementById('btn-revert-global-scope')?.addEventListener('click', () => {
      state.currentProject = '';
      const projSel = document.getElementById('project-selector');
      if (projSel) projSel.value = '';
      state.scopeError = null;
      refreshDashboard(true, true);
    });
  }

  // Dashboard Sync with Safe Polling & Promise Coalescing
  async function refreshDashboard(showErrorBanner = true, forceRedraw = false) {
    if (forceRedraw) queuedForceRedraw = true;
    if (showErrorBanner) queuedShowErrorBanner = true;

    if (activeRefreshPromise) {
      hasQueuedRefresh = true;
      return new Promise((resolve) => {
        queuedRefreshResolvers.push({ resolve });
      });
    }

    let finalOutcome = { success: false };

    activeRefreshPromise = (async () => {
      while (true) {
        const thisEpoch = ++refreshEpoch;
        const requestedProject = state.currentProject;
        const shouldForce = forceRedraw || queuedForceRedraw;
        const shouldShowErr = showErrorBanner || queuedShowErrorBanner;
        queuedForceRedraw = false;
        queuedShowErrorBanner = false;
        hasQueuedRefresh = false;

        try {
          const result = await callBridge('dashboard.get', requestedProject ? { project: requestedProject } : {});
          // Late responses from a prior project or previous epoch must not replace current-project data
          if (thisEpoch === refreshEpoch && state.currentProject === requestedProject && result) {
            updateFooterStatus('connected');
            state.dashboard = result;
            state.dashboardScope = requestedProject;
            state.scopeError = null;
            if (Array.isArray(result.projects)) {
              state.registeredProjects = result.projects;
              updateProjectSelector();
            }
            if (result.settings) {
              state.rawSettings = result.settings;
              if (result.settings.locale === 'en' || result.settings.locale === 'zh-CN') {
                if (window.VelaI18n && window.VelaI18n.getLocale() !== result.settings.locale) {
                  window.VelaI18n.setLocale(result.settings.locale);
                }
              }
            }
            updateGlobalCounters();

            // Check if user has an unsaved settings draft
            const hasSettingsDraft = (state.currentPage === 'settings' && state.settingsDraft !== null);

            // Check if user is actively typing or a modal/drawer is open
            const activeEl = document.activeElement;
            const isEditing = activeEl && (
              activeEl.tagName === 'INPUT' ||
              activeEl.tagName === 'TEXTAREA' ||
              activeEl.tagName === 'SELECT' ||
              activeEl.isContentEditable
            );
            const isModalOpen = !document.getElementById('modal-container').classList.contains('hidden');
            const isDrawerOpen = !document.getElementById('detail-drawer').classList.contains('hidden');

            const snapshotKey = JSON.stringify({
              page: state.currentPage,
              project: state.currentProject,
              data: result
            });
            const isIdentical = state.lastRenderedSnapshotJson === snapshotKey;

            const canRender = shouldForce || (!isEditing && !isModalOpen && !isDrawerOpen && !hasSettingsDraft);
            if (canRender) {
              if (shouldForce || !isIdentical) {
                renderCurrentPage();
                state.lastRenderedSnapshotJson = snapshotKey;
                state.hasPendingSnapshot = false;
              }
            } else {
              if (!isIdentical) {
                state.hasPendingSnapshot = true;
              }
            }

            // If session detail drawer is open, check if selected session has newly ingested messages
            if (isDrawerOpen && state.selectedSessionId && !isModalOpen) {
              checkAndTriggerLiveSessionUpdate(result.sessions);
            }

            hideGlobalError();
            finalOutcome = { success: true, data: result };
          } else {
            // Discarded obsolete epoch/project result
            finalOutcome = { success: false, discarded: true };
          }
        } catch (err) {
          if (thisEpoch === refreshEpoch && state.currentProject === requestedProject) {
            updateFooterStatus('error');
            if (shouldShowErr) {
              showGlobalError(`${t('common.fetchLocalDataFailed')}: ${err.message || t('common.unknown')}`);
            }
            // Invalidate/clear old dashboard if actual scope differs from currentProject,
            // refusing to use stale dashboard under mismatched project scope.
            if (state.dashboardScope !== requestedProject) {
              state.dashboard = null;
              state.dashboardScope = null;
            }
            state.scopeError = {
              project: requestedProject,
              priorProject: state.priorProject || '',
              message: err.message || t('common.unknown')
            };
            updateGlobalCounters();
            renderCurrentPage();
          }
          finalOutcome = { success: false, error: err };
        }

        if (!hasQueuedRefresh) {
          break;
        }
      }
      return finalOutcome;
    })();

    try {
      const outcome = await activeRefreshPromise;
      const resolvers = queuedRefreshResolvers;
      queuedRefreshResolvers = [];
      resolvers.forEach(r => r.resolve(outcome));
      return outcome;
    } finally {
      activeRefreshPromise = null;
    }
  }

  function updateGlobalCounters() {
    const hasValidScope = Boolean(state.dashboard && state.dashboardScope === state.currentProject);
    const badge = document.getElementById('badge-inbox-count');
    if (!hasValidScope) {
      if (badge) badge.classList.add('hidden');
      return;
    }
    const approvals = state.dashboard.approvals || [];
    // Only pending approvals count towards badge
    const pendingCount = approvals.filter(a => {
      const st = (a.state || '').toLowerCase();
      return st === 'pending' || st === 'pending approval' || st === '';
    }).length;

    if (badge) {
      badge.textContent = pendingCount;
      if (pendingCount > 0) badge.classList.remove('hidden');
      else badge.classList.add('hidden');
    }

    const sessions = state.dashboard.sessions || [];
    const runningCount = sessions.filter(s => s.state === 'Running').length;

    if (state.isBridgeAvailable) {
      callBridge('system.updateStatus', {
        running: runningCount,
        approvals: pendingCount
      }).catch(() => {});
    }
  }

  function updateProjectSelector() {
    const sel = document.getElementById('project-selector');
    if (!sel) return;
    const curr = state.currentProject;
    const projects = state.registeredProjects || [];

    const projectKey = JSON.stringify(projects.map(p => ({ v: p.path || p.id, t: p.title || p.name || p.path })));
    if (sel.dataset.lastProjectsKey === projectKey) {
      if (sel.value !== curr) {
        sel.value = curr;
      }
      return;
    }
    sel.dataset.lastProjectsKey = projectKey;

    sel.innerHTML = `<option value="" data-i18n="shell.allProjects">${escapeHtml(t('shell.allProjects'))}</option>`;
    for (const proj of projects) {
      const opt = document.createElement('option');
      opt.value = proj.path || proj.id || '';
      opt.textContent = proj.title || proj.name || proj.path || t('common.unnamedProject');
      if (opt.value === curr) opt.selected = true;
      sel.appendChild(opt);
    }
    sel.value = curr;
  }

  function showGlobalError(msg) {
    const el = document.getElementById('global-error');
    const text = document.getElementById('global-error-text');
    if (el && text) {
      text.textContent = msg;
      el.classList.remove('hidden');
    }
  }

  function hideGlobalError() {
    const el = document.getElementById('global-error');
    if (el) el.classList.add('hidden');
  }

  function setupPolling() {
    if (state.pollTimer) clearInterval(state.pollTimer);
    state.pollTimer = setInterval(() => {
      if (document.visibilityState === 'visible') {
        refreshDashboard(false, false);
      }
    }, 5000);
  }

  // Keyboard Shortcuts & Handlers
  function setupShortcuts() {
    window.addEventListener('keydown', (e) => {
      const isCmdOrCtrl = e.metaKey || e.ctrlKey;
      if (e.key === 'Escape') {
        const modalContainer = document.getElementById('modal-container');
        if (modalContainer && !modalContainer.classList.contains('hidden')) {
          closeModal();
          return;
        }
        const detailDrawer = document.getElementById('detail-drawer');
        if (detailDrawer && !detailDrawer.classList.contains('hidden')) {
          closeDrawer();
          return;
        }
      }
      if (isCmdOrCtrl) {
        if (e.key === 'k' || e.key === 'K') {
          e.preventDefault();
          openSearchModal();
          return;
        }
        if (e.key === ',') {
          e.preventDefault();
          navigateTo('settings');
          return;
        }
        const digit = parseInt(e.key, 10);
        const map = { 1: 'agents', 2: 'workflows', 3: 'setup', 4: 'usage', 5: 'improve', 6: 'lab' };
        if (digit >= 1 && digit <= 6 && map[digit]) {
          e.preventDefault();
          navigateTo(map[digit]);
          return;
        }
      }
    });

    window.addEventListener('vela:navigate', (e) => {
      if (e.detail && e.detail.page) navigateTo(e.detail.page);
    });

    window.addEventListener('vela:refresh', (e) => {
      const isManual = e.detail && e.detail.source === 'user';
      refreshDashboard(false, isManual);
      if (isManual) {
        showToast({ key: 'shell.dataRefreshed' });
      }
    });

    window.addEventListener('vela:notificationRoute', (e) => {
      if (e.detail) {
        handleNotificationRoute(e.detail);
      }
    });

    window.addEventListener('vela:search', () => {
      openSearchModal();
    });
  }

  let activeRouteEpoch = 0;

  async function handleNotificationRoute(detail) {
    if (!detail) return;
    const thisEpoch = ++activeRouteEpoch;

    // 1. Notification click closes stale drawer and modal immediately
    closeDrawer();
    closeModal();

    const source = (detail.source || '').toLowerCase();
    const recordID = detail.recordID || '';
    const rawProject = detail.project || '';
    const kind = (detail.kind || '').toLowerCase();
    const count = Number(detail.count) || 1;
    const sources = Array.isArray(detail.sources) ? detail.sources.map(s => String(s).toLowerCase()) : [];
    const spansProjects = Boolean(detail.spansProjects);
    const isAggregate = Boolean(detail.isAggregate) || (count > 1);

    // 2. Resolve project against known registered projects or explicit global fallback
    // Core explicitly preserves project for a same-project aggregate: honor it, entering the scoped list.
    // Only spansProjects=true or project empty forces global. Unknown/removed project => global.
    let resolvedProject = '';
    if (spansProjects || !rawProject) {
      resolvedProject = '';
    } else {
      const known = (state.registeredProjects || []).find(p => p.path === rawProject || p.id === rawProject);
      if (known) {
        resolvedProject = known.path || known.id || '';
      } else {
        resolvedProject = '';
      }
    }

    const priorProject = state.currentProject;
    state.priorProject = priorProject;
    state.currentProject = resolvedProject;
    const projSel = document.getElementById('project-selector');
    if (projSel) projSel.value = resolvedProject;

    // Invalidate old dashboard immediately if scope differs so prior project data is never reused
    if (state.dashboardScope !== resolvedProject) {
      state.dashboard = null;
      state.dashboardScope = null;
    }

    // 3. Await fresh project data BEFORE rendering category/detail
    const refreshRes = await refreshDashboard(true, true);
    if (thisEpoch !== activeRouteEpoch) return; // Later click/navigation won

    if (!refreshRes || !refreshRes.success) {
      state.dashboard = null;
      state.dashboardScope = null;
      state.scopeError = {
        project: resolvedProject,
        priorProject: priorProject,
        message: (refreshRes && refreshRes.error && refreshRes.error.message) || '无法加载目标工程数据'
      };
      renderCurrentPage();
      return;
    }

    // Require currentProject === resolvedProject and active epoch before proceeding
    if (state.currentProject !== resolvedProject || thisEpoch !== activeRouteEpoch) {
      return;
    }

    // 4. Mixed-source aggregates: concise list-choice modal with real total count and actual categories
    const isMixedSource = (sources.length > 1) || (source === 'mixed');
    if (isMixedSource) {
      openMixedAggregateModal({
        count,
        sources: sources.length > 0 ? sources : ['session', 'run', 'approval'],
        project: resolvedProject
      });
      return;
    }

    // 5. Single-source aggregate or single event
    const effectiveSource = (sources.length === 1 ? sources[0] : source) || (kind === 'approval' ? 'approval' : 'session');

    if (isAggregate) {
      // Single-source aggregate opens the corresponding list in the correctly resolved scope
      if (effectiveSource === 'approval' || kind === 'approval') {
        navigateTo('inbox');
      } else if (effectiveSource === 'run') {
        navigateTo('workflows');
      } else {
        navigateTo('agents');
      }
      return;
    }

    // Single event with recordID
    if (effectiveSource === 'approval' || kind === 'approval') {
      navigateTo('inbox');
    } else if (effectiveSource === 'run') {
      navigateTo('workflows');
      if (recordID) {
        openRunDetail(recordID);
      }
    } else if (effectiveSource === 'session') {
      navigateTo('agents');
      if (recordID) {
        openSessionDetail(recordID);
      }
    } else {
      navigateTo('agents');
    }
  }

  function openMixedAggregateModal({ count, sources, project }) {
    const hasSessions = sources.includes('session');
    const hasRuns = sources.includes('run');
    const hasApprovals = sources.includes('approval');

    const modalBody = `
      <div class="alert-banner alert-info" style="margin-bottom: 14px;">
        <span data-i18n="shell.aggregateNotice" data-i18n-params="${escapeHtml(JSON.stringify({ count }))}">${escapeHtml(t('shell.aggregateNotice', { count }))}</span>
      </div>
      <div style="display: flex; flex-direction: column; gap: 10px;">
        ${hasSessions ? `
          <button class="btn btn-secondary btn-choice-agg" data-target="agents" style="justify-content: flex-start; padding: 10px 14px; text-align: left;">
            <strong style="font-size: 13px;" data-i18n="shell.viewSessions">${escapeHtml(t('shell.viewSessions'))}</strong>
            <span style="font-size: 12px; color: var(--text-secondary); margin-left: 8px;" data-i18n="shell.viewSessionsDesc">${escapeHtml(t('shell.viewSessionsDesc'))}</span>
          </button>
        ` : ''}
        ${hasRuns ? `
          <button class="btn btn-secondary btn-choice-agg" data-target="workflows" style="justify-content: flex-start; padding: 10px 14px; text-align: left;">
            <strong style="font-size: 13px;" data-i18n="shell.viewWorkflows">${escapeHtml(t('shell.viewWorkflows'))}</strong>
            <span style="font-size: 12px; color: var(--text-secondary); margin-left: 8px;" data-i18n="shell.viewWorkflowsDesc">${escapeHtml(t('shell.viewWorkflowsDesc'))}</span>
          </button>
        ` : ''}
        ${hasApprovals ? `
          <button class="btn btn-secondary btn-choice-agg" data-target="inbox" style="justify-content: flex-start; padding: 10px 14px; text-align: left;">
            <strong style="font-size: 13px;" data-i18n="shell.viewApprovals">${escapeHtml(t('shell.viewApprovals'))}</strong>
            <span style="font-size: 12px; color: var(--text-secondary); margin-left: 8px;" data-i18n="shell.viewApprovalsDesc">${escapeHtml(t('shell.viewApprovalsDesc'))}</span>
          </button>
        ` : ''}
      </div>
    `;

    openModal({ key: 'shell.aggregateTitle' }, modalBody, `<button class="btn btn-secondary btn-sm" id="btn-cancel-agg-modal" data-i18n="common.close">${escapeHtml(t('common.close'))}</button>`);
    document.getElementById('btn-cancel-agg-modal')?.addEventListener('click', closeModal);
    document.querySelectorAll('.btn-choice-agg').forEach(btn => {
      btn.addEventListener('click', () => {
        const page = btn.getAttribute('data-target');
        closeModal();
        if (page) navigateTo(page);
      });
    });
  }

  function setupEventListeners() {
    document.querySelectorAll('.nav-link').forEach(link => {
      link.addEventListener('click', () => {
        const page = link.getAttribute('data-page');
        if (page) navigateTo(page);
      });
    });

    const projSel = document.getElementById('project-selector');
    if (projSel) {
      projSel.addEventListener('change', (e) => {
        activeRouteEpoch++; // User project change invalidates pending notification routes
        renderGeneration++;
        closeDrawer(); // Explicit project selector change should close stale detail
        const priorProj = state.currentProject;
        state.priorProject = priorProj;
        state.currentProject = e.target.value;
        if (state.dashboardScope !== state.currentProject) {
          state.dashboard = null;
          state.dashboardScope = null;
        }
        renderCurrentPage();
        refreshDashboard(true, true);
      });
    }

    const btnAddProject = document.getElementById('btn-add-project');
    if (btnAddProject) {
      btnAddProject.addEventListener('click', async () => {
        try {
          const selectedDir = await callBridge('system.chooseProject');
          if (selectedDir) {
            await callBridge('projects.add', { path: selectedDir });
            showToast({ key: 'shell.projectConnected', params: { dir: selectedDir } });
            await refreshDashboard(true, true);
          }
        } catch (err) {
          showToast({ key: 'shell.addProjectFailed', params: { error: err.message } }, 'error');
        }
      });
    }

    const btnQuickSearch = document.getElementById('btn-quick-search');
    if (btnQuickSearch) {
      btnQuickSearch.addEventListener('click', openSearchModal);
    }

    const btnRetry = document.getElementById('btn-retry-global');
    if (btnRetry) {
      btnRetry.addEventListener('click', () => refreshDashboard(true, true));
    }

    const btnCloseDrawer = document.getElementById('btn-close-drawer');
    const drawerBackdrop = document.getElementById('drawer-backdrop');
    if (btnCloseDrawer) btnCloseDrawer.addEventListener('click', closeDrawer);
    if (drawerBackdrop) drawerBackdrop.addEventListener('click', closeDrawer);

    const btnCloseModal = document.getElementById('btn-close-modal');
    const modalBackdrop = document.getElementById('modal-backdrop');
    if (btnCloseModal) btnCloseModal.addEventListener('click', closeModal);
    if (modalBackdrop) modalBackdrop.addEventListener('click', closeModal);

    window.addEventListener('resize', () => {
      const drawer = document.getElementById('detail-drawer');
      if (drawer && !drawer.classList.contains('hidden')) {
        const isWide = window.innerWidth >= 1150;
        document.body.classList.toggle('has-inspector-open', isWide);
        const backdrop = document.getElementById('drawer-backdrop');
        if (backdrop) {
          if (isWide) {
            backdrop.classList.add('hidden');
          } else {
            backdrop.classList.remove('hidden');
          }
        }
        if (isWide && drawerTrapHandler) {
          document.removeEventListener('keydown', drawerTrapHandler, true);
          drawerTrapHandler = null;
        } else if (!isWide && !drawerTrapHandler) {
          drawerTrapHandler = function(e) {
            const modal = document.getElementById('modal-container');
            const isModalOpen = modal && !modal.classList.contains('hidden');
            if (!isModalOpen && drawer && !drawer.classList.contains('hidden')) {
              trapFocus(drawer, e);
            }
          };
          document.addEventListener('keydown', drawerTrapHandler, true);
        }
      }
    });

    window.addEventListener('vela:localeChanged', (e) => {
      const incoming = e && e.detail && e.detail.locale;
      if (incoming === 'zh-CN' || incoming === 'en') {
        if (window.VelaI18n) {
          window.VelaI18n.setLocale(incoming);
        }
        state.rawSettings = Object.assign({}, state.rawSettings, { locale: incoming });
        const localeSel = document.getElementById('setting-locale');
        if (localeSel && localeSel.value !== incoming) {
          localeSel.value = incoming;
        }
      }
    });
  }

  function syncNavLinks() {
    document.querySelectorAll('.nav-link').forEach(link => {
      const isCurrent = link.getAttribute('data-page') === state.currentPage;
      link.classList.toggle('active', isCurrent);
      if (isCurrent) {
        link.setAttribute('aria-current', 'page');
      } else {
        link.removeAttribute('aria-current');
      }
    });
  }

  function navigateTo(page) {
    if (!page) return;
    activeRouteEpoch++; // User navigation invalidates pending notification routes
    renderGeneration++;
    if (state.currentPage !== page) {
      closeDrawer();
    }
    state.currentPage = page;
    state.settingsDraft = null;
    syncNavLinks();
    renderCurrentPage();
  }

  // =========================================================================
  // VIEW RENDERERS
  // =========================================================================

  function renderCurrentPage() {
    const container = document.getElementById('page-container');
    if (!container) return;
    document.body.dataset.page = state.currentPage;
    const hasValidScopeDashboard = (state.dashboard !== null && state.dashboardScope === state.currentProject);
    document.body.dataset.ready = hasValidScopeDashboard ? 'true' : 'false';
    syncNavLinks();

    // Settings view does not depend on project-scoped dashboard and can always render with preserved rawSettings
    if (state.currentPage === 'settings') {
      renderSettingsView(container);
      return;
    }

    // For all project-scoped views: if dashboard is missing or its actual scope differs from currentProject,
    // refuse to render stale data from another project and display the honest target-scope error/retry view!
    if (!hasValidScopeDashboard) {
      renderScopeErrorView(container);
      return;
    }

    switch (state.currentPage) {
      case 'agents': renderAgentsView(container); break;
      case 'workflows': renderWorkflowsView(container); break;
      case 'setup': renderSetupView(container); break;
      case 'memory': renderMemoryView(container); break;
      case 'usage': renderUsageView(container); break;
      case 'improve': renderImproveView(container); break;
      case 'lab': renderLabView(container); break;
      case 'inbox': renderInboxView(container); break;
      default: renderAgentsView(container);
    }
  }

  function renderMemoryView(container) {
    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="memory.title">${t('memory.title')}</h1>
          <p data-i18n="memory.subtitle">${t('memory.subtitle')}</p>
        </div>
      </div>
      <div id="memory-page-content"></div>
    `;
    const target = document.getElementById('memory-page-content');
    if (target) renderMemorySection(target);
  }

  // -------------------------------------------------------------------------
  // 1. AGENTS VIEW
  // -------------------------------------------------------------------------
  function renderAgentsView(container) {
    const sessions = (state.dashboard && state.dashboard.sessions) || [];
    const filteredSessions = sessions.filter(s => {
      if (state.currentProject && s.project !== state.currentProject) return false;
      return true;
    });

    const runningCount = filteredSessions.filter(s => {
      const st = (s.state || '').trim().toLowerCase();
      return st === 'running';
    }).length;

    const hasCopilot = filteredSessions.some(s => (s.provider || '').toLowerCase() === 'copilot');

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="sessions.title">${escapeHtml(t('sessions.title'))}</h1>
          <p data-i18n="sessions.subtitle" data-i18n-params="${escapeHtml(JSON.stringify({ total: filteredSessions.length, running: runningCount }))}">${escapeHtml(t('sessions.subtitle', { total: filteredSessions.length, running: runningCount }))}</p>
        </div>
        <div class="page-actions">
          <button id="btn-refresh-sessions" class="btn btn-secondary btn-sm" data-i18n="sessions.btnRefresh">${escapeHtml(t('sessions.btnRefresh'))}</button>
          <button id="btn-add-project-agents" class="btn btn-primary btn-sm" data-i18n="sessions.btnAddProject">${escapeHtml(t('sessions.btnAddProject'))}</button>
        </div>
      </div>

      <div class="toolbar-bar">
        <div class="toolbar-filters">
          <input type="search" id="session-search-input" class="filter-input" data-i18n-placeholder="sessions.searchPlaceholder" placeholder="${escapeHtml(t('sessions.searchPlaceholder'))}" data-i18n-title="sessions.searchTitle" title="${escapeHtml(t('sessions.searchTitle'))}" style="width: 240px;" value="${escapeHtml(state.sessionFilterQuery)}">
          <select id="session-provider-filter" class="filter-select">
            <option value="" data-i18n="sessions.filterAllProviders">${escapeHtml(t('sessions.filterAllProviders'))}</option>
            <option value="claude" ${(state.sessionProviderFilter || '').toLowerCase() === 'claude' ? 'selected' : ''}>Claude Code</option>
            <option value="codex" ${(state.sessionProviderFilter || '').toLowerCase() === 'codex' ? 'selected' : ''}>Codex</option>
            <option value="cursor" ${(state.sessionProviderFilter || '').toLowerCase() === 'cursor' ? 'selected' : ''}>Cursor</option>
            ${hasCopilot ? `<option value="copilot" ${(state.sessionProviderFilter || '').toLowerCase() === 'copilot' ? 'selected' : ''}>GitHub Copilot</option>` : ''}
          </select>
          <select id="session-status-filter" class="filter-select">
            <option value="" data-i18n="sessions.filterAllStatuses">${escapeHtml(t('sessions.filterAllStatuses'))}</option>
            <option value="running" ${(state.sessionStatusFilter || '').toLowerCase() === 'running' ? 'selected' : ''} data-i18n="sessions.statusRunning">${escapeHtml(t('sessions.statusRunning'))}</option>
            <option value="idle" ${(state.sessionStatusFilter || '').toLowerCase() === 'idle' ? 'selected' : ''} data-i18n="sessions.statusIdle">${escapeHtml(t('sessions.statusIdle'))}</option>
            <option value="completed" ${(state.sessionStatusFilter || '').toLowerCase() === 'completed' ? 'selected' : ''} data-i18n="sessions.statusCompleted">${escapeHtml(t('sessions.statusCompleted'))}</option>
            <option value="needs approval" ${(state.sessionStatusFilter || '').toLowerCase() === 'needs approval' ? 'selected' : ''} data-i18n="sessions.statusNeedsApproval">${escapeHtml(t('sessions.statusNeedsApproval'))}</option>
            <option value="error" ${(state.sessionStatusFilter || '').toLowerCase() === 'error' ? 'selected' : ''} data-i18n="sessions.statusError">${escapeHtml(t('sessions.statusError'))}</option>
            <option value="stopped" ${(state.sessionStatusFilter || '').toLowerCase() === 'stopped' ? 'selected' : ''} data-i18n="sessions.statusStopped">${escapeHtml(t('sessions.statusStopped'))}</option>
            <option value="unknown" ${(state.sessionStatusFilter || '').toLowerCase() === 'unknown' ? 'selected' : ''} data-i18n="sessions.statusUnknown">${escapeHtml(t('sessions.statusUnknown'))}</option>
          </select>
          <button id="btn-clear-session-filters" class="btn btn-ghost btn-sm ${(state.sessionFilterQuery || state.sessionProviderFilter || state.sessionStatusFilter) ? '' : 'hidden'}" data-i18n="sessions.btnClearFilters">${escapeHtml(t('sessions.btnClearFilters'))}</button>
        </div>
      </div>

      <div class="session-source-note" role="note">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>
        <span data-i18n="sessions.sourceNote">${escapeHtml(t('sessions.sourceNote'))}</span>
      </div>

      <div id="sessions-container" class="sessions-container" role="region" data-i18n-aria-label="sessions.containerAria" aria-label="${escapeHtml(t('sessions.containerAria'))}">
        <div id="sessions-grouped-lists"></div>
      </div>

      <div id="sessions-empty-state" class="empty-state hidden"></div>
    `;

    applySessionFilters(filteredSessions);

    const searchInput = document.getElementById('session-search-input');
    const provFilter = document.getElementById('session-provider-filter');
    const statusFilter = document.getElementById('session-status-filter');
    const clearFiltersBtn = document.getElementById('btn-clear-session-filters');

    const filterHandler = () => {
      state.sessionFilterQuery = (searchInput.value || '').trim();
      state.sessionProviderFilter = (provFilter.value || '').trim().toLowerCase();
      state.sessionStatusFilter = (statusFilter.value || '').trim().toLowerCase();
      applySessionFilters(filteredSessions);
    };

    searchInput.addEventListener('input', filterHandler);
    provFilter.addEventListener('change', filterHandler);
    statusFilter.addEventListener('change', filterHandler);

    if (clearFiltersBtn) {
      clearFiltersBtn.addEventListener('click', () => {
        state.sessionFilterQuery = '';
        state.sessionProviderFilter = '';
        state.sessionStatusFilter = '';
        if (searchInput) searchInput.value = '';
        if (provFilter) provFilter.value = '';
        if (statusFilter) statusFilter.value = '';
        applySessionFilters(filteredSessions);
      });
    }

    document.getElementById('btn-refresh-sessions').addEventListener('click', async () => {
      try {
        await callBridge('sessions.refresh');
        await refreshDashboard(true, true);
        showToast({ key: 'sessions.refreshedToast' });
      } catch (err) {
        showToast({ key: 'sessions.refreshFailedToast', params: { error: err.message } }, 'error');
      }
    });

    document.getElementById('btn-add-project-agents').addEventListener('click', () => {
      document.getElementById('btn-add-project').click();
    });
  }

  function applySessionFilters(filteredSessions) {
    const q = (state.sessionFilterQuery || '').toLowerCase();
    const prov = (state.sessionProviderFilter || '').trim().toLowerCase();
    const st = (state.sessionStatusFilter || '').trim().toLowerCase();

    const isFilterActive = !!(q || prov || st);
    const clearFiltersBtn = document.getElementById('btn-clear-session-filters');
    if (clearFiltersBtn) {
      clearFiltersBtn.classList.toggle('hidden', !isFilterActive);
    }

    const res = filteredSessions.filter(s => {
      const sProv = (s.provider || '').trim().toLowerCase();
      if (prov && sProv !== prov) return false;
      const sState = (s.state || '').trim().toLowerCase();
      if (st && sState !== st) return false;
      if (q) {
        const matchTitle = (s.title || '').toLowerCase().includes(q);
        const matchModel = (s.model || '').toLowerCase().includes(q);
        const matchProj = (s.project || '').toLowerCase().includes(q);
        if (!matchTitle && !matchModel && !matchProj) return false;
      }
      return true;
    });

    renderSessionRows(res, filteredSessions.length, isFilterActive);
  }

  function renderSessionRows(sessionsList, totalProjectSessions, isFilterActive) {
    const container = document.getElementById('sessions-container');
    const groupedListEl = document.getElementById('sessions-grouped-lists');
    const emptyState = document.getElementById('sessions-empty-state');
    const noteEl = document.querySelector('.session-source-note');
    if (!container || !groupedListEl) return;

    if (sessionsList.length === 0) {
      groupedListEl.innerHTML = '';
      container.classList.add('hidden');
      if (noteEl) noteEl.classList.add('hidden');
      if (emptyState) {
        emptyState.classList.remove('hidden');
        if (state.registeredProjects.length === 0) {
          // State 1: No connected projects
          emptyState.innerHTML = `
            <div class="empty-state-title" data-i18n="sessions.emptyNoProjectsTitle">${escapeHtml(t('sessions.emptyNoProjectsTitle'))}</div>
            <div class="empty-state-desc" data-i18n="sessions.emptyNoProjectsDesc">${escapeHtml(t('sessions.emptyNoProjectsDesc'))}</div>
            <button id="btn-empty-connect-proj" class="btn btn-primary btn-sm" style="margin-top: 12px;" data-i18n="sessions.emptyBtnConnect">${escapeHtml(t('sessions.emptyBtnConnect'))}</button>
          `;
          const btn = document.getElementById('btn-empty-connect-proj');
          if (btn) btn.addEventListener('click', () => document.getElementById('btn-add-project').click());
        } else if (totalProjectSessions === 0 && !isFilterActive) {
          // State 2: Connected project has 0 logs
          emptyState.innerHTML = `
            <div class="empty-state-title" data-i18n="sessions.emptyNoLogsTitle">${escapeHtml(t('sessions.emptyNoLogsTitle'))}</div>
            <div class="empty-state-desc" data-i18n="sessions.emptyNoLogsDesc">${escapeHtml(t('sessions.emptyNoLogsDesc'))}</div>
            <button id="btn-empty-refresh-scan" class="btn btn-secondary btn-sm" style="margin-top: 12px;" data-i18n="sessions.emptyBtnRefresh">${escapeHtml(t('sessions.emptyBtnRefresh'))}</button>
          `;
          const btn = document.getElementById('btn-empty-refresh-scan');
          if (btn) btn.addEventListener('click', async () => {
            try {
              await callBridge('sessions.refresh');
              await refreshDashboard(true, true);
              showToast({ key: 'sessions.refreshedToast' });
            } catch (err) {
              showToast({ key: 'sessions.refreshFailedToast', params: { error: err.message } }, 'error');
            }
          });
        } else {
          // State 3: Filter query returned 0 matches
          emptyState.innerHTML = `
            <div class="empty-state-title" data-i18n="sessions.emptyNoMatchTitle">${escapeHtml(t('sessions.emptyNoMatchTitle'))}</div>
            <div class="empty-state-desc" data-i18n="sessions.emptyNoMatchDesc">${escapeHtml(t('sessions.emptyNoMatchDesc'))}</div>
            <button id="btn-empty-clear-filters" class="btn btn-secondary btn-sm" style="margin-top: 12px;" data-i18n="sessions.emptyBtnClear">${escapeHtml(t('sessions.emptyBtnClear'))}</button>
          `;
          const btn = document.getElementById('btn-empty-clear-filters');
          if (btn) btn.addEventListener('click', () => {
            state.sessionFilterQuery = '';
            state.sessionProviderFilter = '';
            state.sessionStatusFilter = '';
            const searchInput = document.getElementById('session-search-input');
            const provFilter = document.getElementById('session-provider-filter');
            const statusFilter = document.getElementById('session-status-filter');
            if (searchInput) searchInput.value = '';
            if (provFilter) provFilter.value = '';
            if (statusFilter) statusFilter.value = '';
            const clearFiltersBtn = document.getElementById('btn-clear-session-filters');
            if (clearFiltersBtn) clearFiltersBtn.classList.add('hidden');
            const projSessions = ((state.dashboard && state.dashboard.sessions) || []).filter(s => {
              if (state.currentProject && s.project !== state.currentProject) return false;
              return true;
            });
            applySessionFilters(projSessions);
          });
        }
      }
      return;
    }

    container.classList.remove('hidden');
    if (noteEl) noteEl.classList.remove('hidden');
    if (emptyState) emptyState.classList.add('hidden');

    const groups = [
      {
        key: 'attention',
        labelKey: 'sessions.groupAttention',
        filter: s => {
          const st = (s.state || '').trim().toLowerCase();
          return st === 'needs approval' || st === 'needs_approval' || st === 'error' || st === 'failed';
        }
      },
      {
        key: 'active',
        labelKey: 'sessions.groupActive',
        filter: s => (s.state || '').trim().toLowerCase() === 'running'
      },
      {
        key: 'completed',
        labelKey: 'sessions.groupCompleted',
        filter: s => (s.state || '').trim().toLowerCase() === 'completed'
      },
      {
        key: 'idle_or_unknown',
        labelKey: 'sessions.groupIdleOrUnknown',
        filter: s => {
          const st = (s.state || '').trim().toLowerCase();
          return st !== 'needs approval' && st !== 'needs_approval' && st !== 'error' && st !== 'failed' && st !== 'running' && st !== 'completed';
        }
      }
    ];

    const groupHtml = groups.map(group => {
      const items = sessionsList.filter(group.filter);
      if (items.length === 0) return '';

      items.sort((a, b) => {
        const ta = new Date(a.updatedAt || a.lastActivity || a.startedAt || 0).getTime();
        const tb = new Date(b.updatedAt || b.lastActivity || b.startedAt || 0).getTime();
        return tb - ta;
      });

      const cardsHtml = items.map(s => {
        const stateBadge = getSessionStateBadge(s.state);
        let statusTitleKey = null;
        if (s.statusSource && s.statusEvidence) {
          statusTitleKey = 'sessions.statusSourceAndEvidence';
        } else if (s.statusSource && s.statusInferred) {
          statusTitleKey = 'sessions.statusSourceAndInferred';
        } else if (s.statusSource) {
          statusTitleKey = 'sessions.statusSource';
        } else if (s.statusEvidence) {
          statusTitleKey = 'sessions.statusEvidence';
        } else if (s.statusInferred) {
          statusTitleKey = 'sessions.statusEvidenceInferred';
        }

        const rawTitle = s.title || '';
        const rawProvider = s.provider || 'AI';
        const rawState = s.state || '-';

        const rowParams = {
          provider: rawProvider,
          state: rawState
        };
        if (rawTitle) rowParams.title = rawTitle;
        if (s.statusSource) rowParams.source = s.statusSource;
        if (s.statusEvidence) rowParams.evidence = s.statusEvidence;

        const ariaKey = rawTitle ? 'sessions.viewSessionAria' : 'sessions.viewSessionAriaUnnamed';
        const ariaParams = rawTitle
          ? { title: rawTitle, provider: rawProvider, state: rawState }
          : { provider: rawProvider, state: rawState };

        const viewAria = t(ariaKey, ariaParams);
        const cellTooltip = statusTitleKey ? t(statusTitleKey, rowParams) : '';

        const projectName = s.project ? s.project.split('/').filter(Boolean).pop() : '';
        const providerName = (s.provider || 'ai').toLowerCase();
        const displayTitle = rawTitle || t('sessions.unnamedSession');

        return `
          <li class="session-card clickable-row ${state.selectedSessionId === s.id ? 'selected' : ''}" role="listitem" data-id="${escapeHtml(s.id)}" tabindex="0"${statusTitleKey ? ` title="${escapeHtml(cellTooltip)}" data-i18n-title="${statusTitleKey}"` : ''} aria-label="${escapeHtml(viewAria)}" data-i18n-aria-label="${ariaKey}" data-i18n-params="${escapeHtml(JSON.stringify(rowParams))}">
            <div class="session-card-main">
              <div class="session-card-header">
                <span class="provider-badge provider-${escapeHtml(providerName)}" ${!s.provider ? 'data-i18n="provider.unknown"' : ''}>${escapeHtml(formatProviderName(s.provider))}</span>
                <button type="button" class="session-title-btn" data-id="${escapeHtml(s.id)}" title="${escapeHtml(displayTitle)}" aria-label="${escapeHtml(viewAria)}"${rawTitle ? '' : ' data-i18n="sessions.unnamedSession" data-i18n-title="sessions.unnamedSession"'} data-i18n-aria-label="${ariaKey}" data-i18n-params="${escapeHtml(JSON.stringify(ariaParams))}">
                  ${escapeHtml(displayTitle)}
                </button>
              </div>
              <div class="session-card-meta">
                ${projectName ? `
                  <span class="session-meta-project" title="${escapeHtml(s.project || '')}">
                    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path></svg>
                    ${escapeHtml(projectName)}
                  </span>
                ` : ''}
                ${s.branch ? `
                  <span class="session-meta-branch" title="${escapeHtml(t('sessions.branch', { branch: s.branch }))}" data-i18n-title="sessions.branch" data-i18n-params="${escapeHtml(JSON.stringify({ branch: s.branch }))}">
                    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><line x1="6" y1="3" x2="6" y2="15"></line><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path></svg>
                    ${escapeHtml(s.branch)}
                  </span>
                ` : ''}
                ${s.messageCount != null ? `
                  <span class="session-meta-messages" data-i18n="sessions.messageCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: s.messageCount }))}">
                    ${escapeHtml(t('sessions.messageCount', { count: s.messageCount }))}
                  </span>
                ` : ''}
              </div>
            </div>
            <div class="session-card-status">
              ${stateBadge}
              <span class="session-card-time">${formatTime(s.updatedAt || s.lastActivity)}</span>
            </div>
          </li>
        `;
      }).join('');

      return `
        <section class="session-group session-group-${group.key}" data-i18n-aria-label="${group.labelKey}" aria-label="${escapeHtml(t(group.labelKey))}">
          <div class="session-group-header">
            <div class="session-group-title">— <span data-i18n="${group.labelKey}">${escapeHtml(t(group.labelKey))}</span></div>
            <span class="session-group-count">${items.length}</span>
          </div>
          <ul class="session-card-list" role="list">
            ${cardsHtml}
          </ul>
        </section>
      `;
    }).join('');

    groupedListEl.innerHTML = groupHtml;

    groupedListEl.querySelectorAll('.session-card').forEach(card => {
      const openCard = (triggerEl) => {
        const id = card.getAttribute('data-id');
        groupedListEl.querySelectorAll('.session-card').forEach(c => c.classList.toggle('selected', c.getAttribute('data-id') === id));
        openSessionDetail(id, triggerEl || card.querySelector('.session-title-btn') || card);
      };

      card.addEventListener('click', () => {
        const trigger = card.querySelector('.session-title-btn') || card;
        openCard(trigger);
      });

      card.addEventListener('keydown', (e) => {
        if (e.target === card && (e.key === 'Enter' || e.key === ' ')) {
          e.preventDefault();
          openCard(card.querySelector('.session-title-btn') || card);
        }
      });

      const titleBtn = card.querySelector('.session-title-btn');
      if (titleBtn) {
        titleBtn.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            e.stopPropagation();
            openCard(titleBtn);
          }
        });
      }
    });
  }

  function getSessionStateBadge(stateStr) {
    const s = (stateStr || '').toLowerCase();
    switch (s) {
      case 'running':
        return `<span class="status-badge status-blue"><span class="status-pulse-dot" style="background-color: var(--color-accent);"></span> <span data-i18n="sessions.statusRunning">${escapeHtml(t('sessions.statusRunning'))}</span></span>`;
      case 'completed':
        return `<span class="status-badge status-sage">✓ <span data-i18n="sessions.statusCompleted">${escapeHtml(t('sessions.statusCompleted'))}</span></span>`;
      case 'needs approval':
      case 'needs_approval':
        return `<span class="status-badge status-amber" data-i18n="sessions.statusNeedsApproval">${escapeHtml(t('sessions.statusNeedsApproval'))}</span>`;
      case 'error':
        return `<span class="status-badge status-red">✕ <span data-i18n="sessions.statusError">${escapeHtml(t('sessions.statusError'))}</span></span>`;
      case 'failed':
        return `<span class="status-badge status-red">✕ <span data-i18n="sessions.statusError">${escapeHtml(t('sessions.statusError'))}</span></span>`;
      case 'idle':
        return `<span class="status-badge status-neutral" data-i18n="sessions.statusIdle">${escapeHtml(t('sessions.statusIdle'))}</span>`;
      case 'stopped':
        return `<span class="status-badge status-neutral" data-i18n="sessions.statusStopped">${escapeHtml(t('sessions.statusStopped'))}</span>`;
      case 'unknown':
      case '未知':
      case '未知（仅日志）':
        return `<span class="status-badge status-neutral" data-i18n="sessions.statusUnknown">${escapeHtml(t('sessions.statusUnknown'))}</span>`;
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(stateStr || t('sessions.statusUnknown'))}</span>`;
    }
  }

  function renderSessionDetailContent(session, drawerBody) {
    const messages = session.messages || [];
    const isTruncated = Boolean(session.messagesTruncated || session.isPartial || session.partial);

    function isSafeCount(val) {
      return typeof val === 'number' && Number.isSafeInteger(val) && val >= 0;
    }

    function formatSessionTokenVal(exactVal, observedVal) {
      if (isSafeCount(exactVal)) {
        return formatNumber(exactVal);
      }
      if (isSafeCount(observedVal)) {
        return `${formatNumber(observedVal)} <span class="status-badge status-amber" style="font-size: 9px; padding: 1px 4px;" data-i18n="sessions.tokenObservedPart">${escapeHtml(t('sessions.tokenObservedPart'))}</span>`;
      }
      return `<span data-i18n="common.none">${escapeHtml(t('common.none'))}</span>`;
    }

    const hasAnyToken = isSafeCount(session.tokenInput) || isSafeCount(session.tokenOutput) ||
                        isSafeCount(session.observedTokenInput) || isSafeCount(session.observedTokenOutput);

    const tokenInputDisp = formatSessionTokenVal(session.tokenInput, session.observedTokenInput);
    const tokenOutputDisp = formatSessionTokenVal(session.tokenOutput, session.observedTokenOutput);
    const tokensDisp = hasAnyToken ? `${tokenInputDisp} / ${tokenOutputDisp}` : `<span data-i18n="common.none">${escapeHtml(t('common.none'))}</span>`;

    function formatSessionUsageStatus(st) {
      if (!st) return '';
      switch (st) {
        case 'complete':
          return `<span class="status-badge status-sage" data-i18n="sessions.usageComplete">${escapeHtml(t('sessions.usageComplete'))}</span>`;
        case 'partial':
          return `<span class="status-badge status-amber" data-i18n="sessions.usagePartial">${escapeHtml(t('sessions.usagePartial'))}</span>`;
        case 'overflow':
          return `<span class="status-badge status-red" data-i18n="sessions.usageOverflow">${escapeHtml(t('sessions.usageOverflow'))}</span>`;
        case 'unavailable':
          return `<span class="status-badge status-neutral" data-i18n="sessions.usageUnavailable">${escapeHtml(t('sessions.usageUnavailable'))}</span>`;
        default:
          return `<span class="status-badge status-neutral">${escapeHtml(st)}</span>`;
      }
    }

    drawerBody.innerHTML = `
      <div class="session-status-banner card" style="padding: 10px 14px; margin-bottom: 16px; background: var(--bg-subtle);">
        <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap;">
          <div style="display: flex; align-items: center; gap: 8px; flex-wrap: nowrap;">
            ${getSessionStateBadge(session.state)}
            ${session.statusInferred ? `<span class="status-badge status-amber" style="white-space: nowrap;" data-i18n="sessions.badgeInferred">${escapeHtml(t('sessions.badgeInferred'))}</span>` : ''}
            ${isTruncated ? `<span class="status-badge status-neutral" style="white-space: nowrap;" data-i18n="sessions.badgeTruncated">${escapeHtml(t('sessions.badgeTruncated'))}</span>` : ''}
          </div>
          <div style="font-size: 12px; color: var(--text-secondary); white-space: nowrap;">
            ${escapeHtml(session.provider || 'AI')}${session.model ? ` · ${escapeHtml(session.model)}` : ''}
          </div>
        </div>
        ${session.statusInferred ? `
          <div style="font-size: 11px; color: var(--text-muted); margin-top: 6px;">
            <span data-i18n="sessions.evidencePrefix">${escapeHtml(t('sessions.evidencePrefix'))}</span>${escapeHtml(session.statusEvidence || session.statusSource || t('sessions.defaultInferredEvidence'))}
          </div>
        ` : ''}
        ${isTruncated ? `
          <div style="font-size: 11px; color: var(--text-muted); margin-top: 4px;" data-i18n="sessions.truncatedNotice">
            ${escapeHtml(t('sessions.truncatedNotice'))}
          </div>
        ` : ''}
      </div>

      <div style="margin-bottom: 20px;">
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
          <h3 style="font-size: 14px; font-weight: 600;" data-i18n="sessions.messagesTitle" data-i18n-params="${escapeHtml(JSON.stringify({ count: messages.length }))}">${escapeHtml(t('sessions.messagesTitle', { count: messages.length }))}</h3>
          <span style="font-size: 12px; color: var(--text-secondary);" data-i18n="sessions.saveMsgMemoryHint">${escapeHtml(t('sessions.saveMsgMemoryHint'))}</span>
        </div>

        <div style="display: flex; flex-direction: column; gap: 12px;">
          ${messages.length === 0 ? `<div class="text-secondary" style="font-size: 13px; padding: 24px 0; text-align: center;" data-i18n="sessions.noMessages">${escapeHtml(t('sessions.noMessages'))}</div>` : ''}
          ${messages.map((m, idx) => {
            const msgId = m.id ? String(m.id) : '';
            const msgIdAttr = msgId ? `id="session-msg-${escapeHtml(msgId)}"` : '';
            const msgDataAttr = msgId ? `data-message-id="${escapeHtml(msgId)}"` : `data-message-index="${idx}"`;
            return `
            <div class="card session-message-card" ${msgIdAttr} ${msgDataAttr} tabindex="-1" style="margin-bottom: 0; padding: 12px 14px;">
              <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;">
                <div style="display: flex; align-items: center; gap: 8px;">
                  <span class="status-badge status-neutral">${escapeHtml(m.role || 'message')}</span>
                  <span style="font-size: 12px; color: var(--text-muted);">${formatTime(m.timestamp)}</span>
                </div>
                <button class="btn btn-ghost btn-sm btn-save-msg-memory" data-idx="${idx}" data-i18n-title="sessions.saveMsgMemoryTitle" title="${escapeHtml(t('sessions.saveMsgMemoryTitle'))}" data-i18n="sessions.btnSaveMsgMemory">
                  ${escapeHtml(t('sessions.btnSaveMsgMemory'))}
                </button>
              </div>
              <div style="font-size: 13px; line-height: 1.55; white-space: pre-wrap; word-break: break-word; color: var(--text-main); font-family: var(--font-system);">${escapeHtml(m.content || '')}</div>
              ${m.tool ? `
                <div style="margin-top: 8px; font-size: 12px; font-family: var(--font-mono); color: var(--text-secondary); background: var(--bg-subtle); padding: 6px 10px; border-radius: 4px; border: 1px solid var(--border-color);">
                  <div style="font-weight: 600; margin-bottom: ${m.input || m.output ? '4px' : '0'};">${escapeHtml(t('sessions.toolCallHeader', { tool: m.tool }))}</div>
                  ${m.input ? `<div style="font-size: 11px; white-space: pre-wrap; word-break: break-all; color: var(--text-muted);">${escapeHtml(typeof m.input === 'string' ? m.input : JSON.stringify(m.input, null, 2))}</div>` : ''}
                  ${m.output ? `<div style="font-size: 11px; white-space: pre-wrap; word-break: break-all; color: var(--text-secondary); margin-top: 4px; border-top: 1px dashed var(--border-color); padding-top: 4px;">${escapeHtml(typeof m.output === 'string' ? m.output : JSON.stringify(m.output, null, 2))}</div>` : ''}
                </div>` : ''}
            </div>
          `;
          }).join('')}
        </div>
      </div>

      <details class="card" style="padding: 12px 14px;" ${messages.length === 0 ? 'open' : ''}>
        <summary style="cursor: pointer; font-size: 13px; font-weight: 600; user-select: none;" data-i18n="sessions.techMetadataSummary">
          ${escapeHtml(t('sessions.techMetadataSummary'))}
        </summary>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; font-size: 12px; margin-top: 12px;">
          <div style="grid-column: 1 / -1;"><span class="text-secondary" data-i18n="sessions.metaSessionId">${escapeHtml(t('sessions.metaSessionId'))}</span> <span class="font-mono" style="word-break: break-all; user-select: all;">${escapeHtml(session.id || '')}</span></div>
          <div><span class="text-secondary" data-i18n="sessions.metaProvider">${escapeHtml(t('sessions.metaProvider'))}</span> <strong>${escapeHtml(session.provider || '-')}</strong></div>
          <div><span class="text-secondary" data-i18n="sessions.metaModel">${escapeHtml(t('sessions.metaModel'))}</span> <span class="font-mono">${escapeHtml(session.model || '-')}</span></div>
          <div><span class="text-secondary" data-i18n="sessions.metaProject">${escapeHtml(t('sessions.metaProject'))}</span> <span class="font-mono">${escapeHtml(session.project || '-')}</span></div>
          <div><span class="text-secondary" data-i18n="sessions.metaBranch">${escapeHtml(t('sessions.metaBranch'))}</span> <span class="font-mono">${escapeHtml(session.branch || '-')}</span></div>
          <div><span class="text-secondary" data-i18n="sessions.metaTokens">${escapeHtml(t('sessions.metaTokens'))}</span> <span class="font-mono">${tokensDisp}</span></div>
          <div><span class="text-secondary" data-i18n="sessions.metaTime">${escapeHtml(t('sessions.metaTime'))}</span> ${formatTime(session.updatedAt)}</div>
          ${session.statusSource ? `<div><span class="text-secondary" data-i18n="sessions.metaStatusSource">${escapeHtml(t('sessions.metaStatusSource'))}</span> <span class="font-mono">${escapeHtml(session.statusSource)}</span></div>` : ''}
          ${session.statusInferred ? `<div><span class="text-secondary" data-i18n="sessions.metaStatusVerdict">${escapeHtml(t('sessions.metaStatusVerdict'))}</span> <span style="color: var(--status-amber-text, #f59e0b);" data-i18n="sessions.metaStatusInferredText" data-i18n-aria-label="sessions.metaStatusInferredText" aria-label="${escapeHtml(t('sessions.metaStatusInferredText'))}">${escapeHtml(t('sessions.metaStatusInferredText'))}</span></div>` : ''}
          ${session.usageStatus ? `<div><span class="text-secondary" data-i18n="sessions.metaUsageStatus">${escapeHtml(t('sessions.metaUsageStatus'))}</span> ${formatSessionUsageStatus(session.usageStatus)}</div>` : ''}
          ${session.usageCoverage ? `<div style="grid-column: 1 / -1;"><span class="text-secondary" data-i18n="sessions.metaUsageCoverage">${escapeHtml(t('sessions.metaUsageCoverage'))}</span> <span class="text-muted" style="word-break: break-all;">${escapeHtml(session.usageCoverage)}</span></div>` : ''}
        </div>
        ${session.sourcePath ? `<div style="margin-top: 10px; font-size: 12px; font-family: var(--font-mono); color: var(--text-muted); word-break: break-all;">${escapeHtml(t('sessions.metaLogPath', { path: session.sourcePath }))}</div>` : ''}
      </details>
    `;

    drawerBody.querySelectorAll('.btn-save-msg-memory').forEach(btn => {
      btn.addEventListener('click', () => {
        const idx = parseInt(btn.getAttribute('data-idx'), 10);
        const msg = messages[idx];
        openCreateOrEditMemoryModal({
          title: t('sessions.memoryExcerptSuffix', { title: session.title || t('sessions.unnamedSession') }),
          content: msg.content || '',
          type: 'fact',
          scope: 'project',
          project: session.project || '',
          branch: session.branch || '',
          sourceSession: session.id,
          sourceMessage: msg.id ? String(msg.id) : ''
        });
      });
    });
  }

  let sessionDetailSequence = 0;
  let liveSessionFetchInProgress = false;

  function computeSessionFingerprint(s) {
    if (!s || typeof s !== 'object') return '';
    const id = s.id || '';
    const rev = s.revision || '';
    const updated = s.updatedAt || '';
    const lastAct = s.lastActivity || '';
    const count = (s.messageCount !== undefined && s.messageCount !== null)
      ? s.messageCount
      : (Array.isArray(s.messages) ? s.messages.length : 0);
    const idxBytes = s.indexedBytes != null ? s.indexedBytes : 0;
    const srcBytes = s.sourceBytes != null ? s.sourceBytes : 0;
    const stateVal = s.state || '';
    const sourcePath = s.sourcePath || '';
    return `${id}:${rev}:${updated}:${lastAct}:${count}:${idxBytes}:${srcBytes}:${stateVal}:${sourcePath}`;
  }

  async function checkAndTriggerLiveSessionUpdate(sessions) {
    if (!state.selectedSessionId || liveSessionFetchInProgress) return;
    const isModalOpen = !document.getElementById('modal-container').classList.contains('hidden');
    if (isModalOpen) return;

    const targetSessionId = state.selectedSessionId;
    const summary = (sessions || []).find(s => s.id === targetSessionId);
    if (!summary) return;

    const summaryFp = computeSessionFingerprint(summary);
    if (!summaryFp) return;

    if (state.loadedSessionDetail && state.loadedSessionDetail.id === targetSessionId) {
      if (state.loadedSessionDetail.fingerprint === summaryFp || state.loadedSessionDetail.rev === summaryFp) {
        return;
      }
    }

    const thisSeq = sessionDetailSequence;
    const thisProject = state.currentProject;
    liveSessionFetchInProgress = true;

    try {
      const session = await callBridge('sessions.get', { id: targetSessionId });
      const drawer = document.getElementById('detail-drawer');
      const drawerBody = document.getElementById('drawer-content');
      const modalNowOpen = !document.getElementById('modal-container').classList.contains('hidden');

      if (thisSeq !== sessionDetailSequence || state.selectedSessionId !== targetSessionId || state.currentProject !== thisProject) {
        return;
      }
      if (!drawer || drawer.classList.contains('hidden') || !drawerBody || modalNowOpen) {
        return;
      }
      if (!session || session.id !== targetSessionId) return;

      const isAtBottom = (drawerBody.scrollHeight - drawerBody.scrollTop - drawerBody.clientHeight) < 35;
      const prevScrollTop = drawerBody.scrollTop;

      const fp = computeSessionFingerprint(session);
      state.loadedSessionDetail = {
        id: session.id,
        fingerprint: fp,
        rev: fp
      };

      renderSessionDetailContent(session, drawerBody);

      if (isAtBottom) {
        drawerBody.scrollTop = drawerBody.scrollHeight;
      } else {
        drawerBody.scrollTop = prevScrollTop;
      }
    } catch (err) {
      console.warn('Live session detail update skipped:', err);
    } finally {
      liveSessionFetchInProgress = false;
    }
  }

  async function openSessionDetail(sessionId, triggerEl = null, targetMessageId = null) {
    const thisSeq = ++sessionDetailSequence;
    const thisProject = state.currentProject;
    state.selectedSessionId = sessionId;
    openDrawer({ key: 'sessions.loadingDetail' }, { key: 'nav.agents' }, triggerEl);

    try {
      const session = await callBridge('sessions.get', { id: sessionId });
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');

      if (thisSeq !== sessionDetailSequence || state.selectedSessionId !== sessionId || !isDrawerOpen || state.currentProject !== thisProject) {
        return;
      }
      if (!session) {
        const e = new Error('sessions.notFound');
        e.i18nKey = 'sessions.notFound';
        throw e;
      }

      const fp = computeSessionFingerprint(session);
      state.loadedSessionDetail = {
        id: session.id,
        fingerprint: fp,
        rev: fp
      };

      const projName = session.project ? session.project.split('/').pop() : null;
      const shortSubtitle = projName
        ? `${session.provider || 'AI'} · ${projName}`
        : { key: 'sessions.sessionSubtitleGlobal', params: { provider: session.provider || 'AI' } };

      setDrawerTitle(session.title ? session.title : { key: 'sessions.sessionDetail' }, shortSubtitle);
      setDrawerCustomActions(`
        <button id="btn-save-checkpoint-modal" class="btn btn-secondary btn-sm" style="flex-shrink: 0;" data-i18n="sessions.btnSaveCheckpoint">${escapeHtml(t('sessions.btnSaveCheckpoint'))}</button>
      `);

      const saveBtn = document.getElementById('btn-save-checkpoint-modal');
      if (saveBtn) {
        saveBtn.addEventListener('click', () => {
          openSaveCheckpointModal(session);
        });
      }

      const drawerBody = document.getElementById('drawer-content');
      if (drawerBody) {
        renderSessionDetailContent(session, drawerBody);

        if (targetMessageId) {
          const escapedId = (typeof CSS !== 'undefined' && CSS.escape) ? CSS.escape(targetMessageId) : targetMessageId;
          const targetEl = drawerBody.querySelector(`[data-message-id="${escapedId}"]`) ||
                           drawerBody.querySelector(`#session-msg-${escapedId}`);
          if (targetEl) {
            targetEl.scrollIntoView({ behavior: 'auto', block: 'center' });
            targetEl.classList.add('message-highlight');
            try { targetEl.focus(); } catch (_) {}
          } else {
            const noticeDiv = document.createElement('div');
            noticeDiv.className = 'alert-banner alert-warning';
            noticeDiv.style.marginBottom = '12px';
            setElementDescriptor(noticeDiv, { key: 'sessions.targetMsgOutOfRange', params: { id: targetMessageId } });
            drawerBody.insertBefore(noticeDiv, drawerBody.firstChild);
          }
        }
      }
    } catch (err) {
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== sessionDetailSequence || state.selectedSessionId !== sessionId || !isDrawerOpen || state.currentProject !== thisProject) {
        return;
      }
      setDrawerTitle({ key: 'common.loadFailed' }, { key: 'common.error' });
      const drawerBody = document.getElementById('drawer-content');
      if (drawerBody) {
        if (err && err.i18nKey) {
          drawerBody.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="sessions.fetchDetailFailedPrefix">${escapeHtml(t('sessions.fetchDetailFailedPrefix'))}</span><span data-i18n="${err.i18nKey}">${escapeHtml(t(err.i18nKey))}</span>
            </div>
          `;
        } else {
          drawerBody.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="sessions.fetchDetailFailedPrefix">${escapeHtml(t('sessions.fetchDetailFailedPrefix'))}</span><span>${escapeHtml(err ? err.message : String(err))}</span>
            </div>
          `;
        }
      }
    }
  }

  async function navigateToSourceMessage(sessionId, messageId = null) {
    if (!sessionId) {
      showToast({ key: 'sessions.noSourceSessionId' }, 'warning');
      return;
    }

    // Preserve dirty forms: do not silently discard unsaved user edits
    const modalContainer = document.getElementById('modal-container');
    if (modalContainer && !modalContainer.classList.contains('hidden')) {
      const inputs = modalContainer.querySelectorAll('input:not([readonly]):not([type="hidden"]), textarea:not([readonly])');
      let hasUnsaved = false;
      inputs.forEach(el => {
        if (el.value && el.value.trim() !== (el.defaultValue || '').trim()) {
          hasUnsaved = true;
        }
      });
      if (hasUnsaved) {
        showToast({ key: 'sessions.unsavedDirtyPrompt' }, 'warning');
        return;
      }
      closeModal();
    }

    const thisEpoch = ++activeRouteEpoch;

    try {
      let targetSession = ((state.dashboard && state.dashboard.sessions) || []).find(s => s.id === sessionId);
      if (!targetSession) {
        targetSession = await callBridge('sessions.get', { id: sessionId });
      }
      if (thisEpoch !== activeRouteEpoch) return;

      if (!targetSession) {
        showToast({ key: 'sessions.sourceSessionNotFound', params: { id: sessionId } }, 'error');
        return;
      }

      // Check project scope
      if (targetSession.project && targetSession.project !== state.currentProject) {
        const isRegistered = (state.registeredProjects || []).some(p => (p.path || p.id) === targetSession.project);
        if (!isRegistered) {
          showToast({ key: 'sessions.projectNotConnected', params: { project: targetSession.project } }, 'warning');
          return;
        }

        // Close prior read-only drawer before changing scope
        closeDrawer();

        const priorProj = state.currentProject;
        state.priorProject = priorProj;
        state.currentProject = targetSession.project;
        const projSel = document.getElementById('project-selector');
        if (projSel) projSel.value = targetSession.project;

        if (state.dashboardScope !== targetSession.project) {
          state.dashboard = null;
          state.dashboardScope = null;
        }

        const refreshRes = await refreshDashboard(true, true);
        if (thisEpoch !== activeRouteEpoch) return;

        if (!refreshRes || !refreshRes.success || state.dashboardScope !== targetSession.project) {
          state.scopeError = {
            project: targetSession.project,
            priorProject: priorProj,
            message: (refreshRes && refreshRes.error && refreshRes.error.message) || t('shell.scopeErrorDefaultDesc')
          };
          renderCurrentPage();
          showToast({ key: 'sessions.switchScopeFailed' }, 'error');
          return;
        }
      }

      if (state.currentPage !== 'agents') {
        // Direct page switch aligned with thisEpoch (avoiding epoch self-invalidation)
        state.currentPage = 'agents';
        state.settingsDraft = null;
        renderGeneration++;
        syncNavLinks();
        renderCurrentPage();
      }

      if (thisEpoch !== activeRouteEpoch) return;

      await openSessionDetail(sessionId, null, messageId);
    } catch (err) {
      if (thisEpoch === activeRouteEpoch) {
        showToast({ key: 'sessions.locateSourceFailed', params: { error: err.message } }, 'error');
      }
    }
  }

  document.addEventListener('click', (e) => {
    const btn = e.target.closest('.btn-open-source');
    if (btn) {
      e.preventDefault();
      const sessionId = btn.getAttribute('data-session-id');
      const messageId = btn.getAttribute('data-message-id');
      if (sessionId) {
        navigateToSourceMessage(sessionId, messageId);
      }
    }
  });

  // -------------------------------------------------------------------------
  // 2. WORKFLOWS VIEW (With deterministic workflow builder draft)
  // -------------------------------------------------------------------------
  function renderWorkflowsView(container) {
    const workflows = (state.dashboard && state.dashboard.workflows) || [];
    const runs = (state.dashboard && state.dashboard.runs) || [];

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="workflows.title">${escapeHtml(t('workflows.title'))}</h1>
          <p data-i18n="workflows.subtitle">${escapeHtml(t('workflows.subtitle'))}</p>
        </div>
        <div class="page-actions">
          <button id="btn-build-wf-prompt" class="btn btn-secondary btn-sm" data-i18n="workflows.btnBuildPrompt">${escapeHtml(t('workflows.btnBuildPrompt'))}</button>
          <button id="btn-new-workflow" class="btn btn-primary btn-sm" data-i18n="workflows.btnNewWorkflow">${escapeHtml(t('workflows.btnNewWorkflow'))}</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.workflowsActiveTab === 'list' ? 'active' : ''}" data-wftab="list" data-i18n="workflows.tabList" data-i18n-params="${escapeHtml(JSON.stringify({ count: workflows.length }))}">${escapeHtml(t('workflows.tabList', { count: workflows.length }))}</button>
        <button class="tab-btn ${state.workflowsActiveTab === 'runs' ? 'active' : ''}" data-wftab="runs" data-i18n="workflows.tabRuns" data-i18n-params="${escapeHtml(JSON.stringify({ count: runs.length }))}">${escapeHtml(t('workflows.tabRuns', { count: runs.length }))}</button>
        <button class="tab-btn ${state.workflowsActiveTab === 'health' ? 'active' : ''}" data-wftab="health" data-i18n="workflows.tabHealth">${escapeHtml(t('workflows.tabHealth'))}</button>
      </div>

      <div id="workflows-tab-content"></div>
    `;

    container.querySelectorAll('[data-wftab]').forEach(tab => {
      tab.addEventListener('click', () => {
        state.workflowsActiveTab = tab.getAttribute('data-wftab');
        container.querySelectorAll('[data-wftab]').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        renderWorkflowsTabContent();
      });
    });

    document.getElementById('btn-new-workflow').addEventListener('click', () => {
      openEditWorkflowModal();
    });

    document.getElementById('btn-build-wf-prompt').addEventListener('click', () => {
      openWorkflowPromptBuilderModal();
    });

    renderWorkflowsTabContent();
  }

  function renderWorkflowsTabContent() {
    const target = document.getElementById('workflows-tab-content');
    if (!target) return;

    if (state.workflowsActiveTab === 'list') {
      const workflows = (state.dashboard && state.dashboard.workflows) || [];
      if (workflows.length === 0) {
        target.innerHTML = `
          <div class="empty-state">
            <div class="empty-state-title" data-i18n="workflows.emptyTitle">${escapeHtml(t('workflows.emptyTitle'))}</div>
            <div class="empty-state-desc" data-i18n="workflows.emptyDesc">${escapeHtml(t('workflows.emptyDesc'))}</div>
            <div style="display: flex; gap: 8px; margin-top: 12px;">
              <button id="btn-empty-build-wf" class="btn btn-secondary btn-sm" data-i18n="workflows.btnEmptyBuild">${escapeHtml(t('workflows.btnEmptyBuild'))}</button>
              <button id="btn-empty-create-wf" class="btn btn-primary btn-sm" data-i18n="workflows.btnEmptyCreate">${escapeHtml(t('workflows.btnEmptyCreate'))}</button>
            </div>
          </div>
        `;
        document.getElementById('btn-empty-create-wf').addEventListener('click', () => openEditWorkflowModal());
        document.getElementById('btn-empty-build-wf').addEventListener('click', () => openWorkflowPromptBuilderModal());
        return;
      }

      target.innerHTML = `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th data-i18n="workflows.colName">${escapeHtml(t('workflows.colName'))}</th>
                <th data-i18n="workflows.colTrigger">${escapeHtml(t('workflows.colTrigger'))}</th>
                <th data-i18n="workflows.colSteps">${escapeHtml(t('workflows.colSteps'))}</th>
                <th data-i18n="workflows.colVersion">${escapeHtml(t('workflows.colVersion'))}</th>
                <th data-i18n="workflows.colStatus">${escapeHtml(t('workflows.colStatus'))}</th>
                <th style="text-align: right; width: 220px;" data-i18n="common.actions">${escapeHtml(t('common.actions'))}</th>
              </tr>
            </thead>
            <tbody>
              ${workflows.map(wf => `
                <tr>
                  <td>
                    <strong>${escapeHtml(wf.title || t('common.unnamedSession'))}</strong>
                    <div style="font-size: 12px; color: var(--text-secondary);">${escapeHtml(wf.description || '-')}</div>
                  </td>
                  <td>
                    <span class="code-badge">${escapeHtml(wf.trigger || 'manual')}</span>
                    ${wf.cron ? `<span style="font-size: 12px; font-family: var(--font-mono); color: var(--text-muted); margin-left: 4px;">${escapeHtml(wf.cron)}</span>` : ''}
                  </td>
                  <td data-i18n="workflows.stepsCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: (wf.steps && wf.steps.length) || 0 }))}">${escapeHtml(t('workflows.stepsCount', { count: (wf.steps && wf.steps.length) || 0 }))}</td>
                  <td><span class="font-mono">v${escapeHtml(String(wf.version || 1))}</span></td>
                  <td>
                    ${wf.enabled !== false ? `<span class="status-badge status-sage" data-i18n="workflows.statusEnabled">${escapeHtml(t('workflows.statusEnabled'))}</span>` : `<span class="status-badge status-neutral" data-i18n="workflows.statusDisabled">${escapeHtml(t('workflows.statusDisabled'))}</span>`}
                  </td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-wf-dryrun" data-id="${escapeHtml(wf.id)}" data-i18n-title="workflows.btnDryRunTitle" title="${escapeHtml(t('workflows.btnDryRunTitle'))}" data-i18n="workflows.btnDryRun">${escapeHtml(t('workflows.btnDryRun'))}</button>
                    <button class="btn btn-primary btn-sm btn-wf-run" data-id="${escapeHtml(wf.id)}" data-i18n="workflows.btnRun">${escapeHtml(t('workflows.btnRun'))}</button>
                    <button class="btn btn-ghost btn-sm btn-wf-edit" data-id="${escapeHtml(wf.id)}" data-i18n="common.edit">${escapeHtml(t('common.edit'))}</button>
                  </td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      `;

      target.querySelectorAll('.btn-wf-run').forEach(btn => {
        btn.addEventListener('click', async () => {
          const id = btn.getAttribute('data-id');
          try {
            const run = await callBridge('workflows.run', { id, dryRun: false });
            showToast({ key: 'workflows.runTriggeredToast' });
            await refreshDashboard(true, true);
            if (run && run.id) openRunDetail(run.id);
          } catch (err) {
            showToast({ key: 'workflows.runFailedToast', params: { error: err.message } }, 'error');
          }
        });
      });

      target.querySelectorAll('.btn-wf-dryrun').forEach(btn => {
        btn.addEventListener('click', async () => {
          const id = btn.getAttribute('data-id');
          try {
            const run = await callBridge('workflows.run', { id, dryRun: true });
            showToast({ key: 'workflows.dryRunCompletedToast' });
            await refreshDashboard(true, true);
            if (run && run.id) openRunDetail(run.id);
          } catch (err) {
            showToast({ key: 'workflows.dryRunFailedToast', params: { error: err.message } }, 'error');
          }
        });
      });

      target.querySelectorAll('.btn-wf-edit').forEach(btn => {
        btn.addEventListener('click', () => {
          const id = btn.getAttribute('data-id');
          const wf = workflows.find(w => w.id === id);
          if (wf) openEditWorkflowModal(wf);
        });
      });

    } else if (state.workflowsActiveTab === 'runs') {
      const runs = (state.dashboard && state.dashboard.runs) || [];
      if (runs.length === 0) {
        target.innerHTML = `
          <div class="empty-state">
            <div class="empty-state-title" data-i18n="workflows.runsEmptyTitle">${escapeHtml(t('workflows.runsEmptyTitle'))}</div>
            <div class="empty-state-desc" data-i18n="workflows.runsEmptyDesc">${escapeHtml(t('workflows.runsEmptyDesc'))}</div>
          </div>
        `;
        return;
      }

      target.innerHTML = `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th data-i18n="workflows.colRunId">${escapeHtml(t('workflows.colRunId'))}</th>
                <th data-i18n="workflows.colWorkflow">${escapeHtml(t('workflows.colWorkflow'))}</th>
                <th data-i18n="workflows.colMode">${escapeHtml(t('workflows.colMode'))}</th>
                <th data-i18n="common.status">${escapeHtml(t('common.status'))}</th>
                <th data-i18n="workflows.colDuration">${escapeHtml(t('workflows.colDuration'))}</th>
                <th data-i18n="workflows.colStartTime">${escapeHtml(t('workflows.colStartTime'))}</th>
                <th style="text-align: right; width: 140px;" data-i18n="common.actions">${escapeHtml(t('common.actions'))}</th>
              </tr>
            </thead>
            <tbody>
              ${runs.map(r => `
                <tr class="clickable-row" data-id="${escapeHtml(r.id)}">
                  <td><span class="code-badge">${escapeHtml(r.id ? r.id.substring(0, 8) : '-')}</span></td>
                  <td><strong>${escapeHtml(r.title || r.workflowId || t('common.unnamedSession'))}</strong></td>
                  <td>${r.dryRun ? `<span class="status-badge status-neutral" data-i18n="workflows.modeDryRun">${escapeHtml(t('workflows.modeDryRun'))}</span>` : `<span class="status-badge status-sage" data-i18n="workflows.modeExecute">${escapeHtml(t('workflows.modeExecute'))}</span>`}</td>
                  <td>${getRunStateBadge(r.state)}</td>
                  <td><span class="font-mono">${r.durationMs ? escapeHtml(String(r.durationMs)) + 'ms' : '-'}</span></td>
                  <td>${formatTime(r.startedAt)}</td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-replay-run" data-id="${escapeHtml(r.id)}" data-i18n="workflows.btnReplay">${escapeHtml(t('workflows.btnReplay'))}</button>
                  </td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      `;

      target.querySelectorAll('tr.clickable-row').forEach(row => {
        row.addEventListener('click', (e) => {
          if (e.target.closest('button')) return;
          openRunDetail(row.getAttribute('data-id'));
        });
      });

      target.querySelectorAll('.btn-replay-run').forEach(btn => {
        btn.addEventListener('click', async (e) => {
          e.stopPropagation();
          const runId = btn.getAttribute('data-id');
          try {
            await callBridge('workflows.replay', { runId });
            showToast({ key: 'workflows.replayedToast' });
            await refreshDashboard(true, true);
          } catch (err) {
            showToast({ key: 'workflows.replayFailedToast', params: { error: err.message } }, 'error');
          }
        });
      });

    } else if (state.workflowsActiveTab === 'health') {
      target.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title" data-i18n="workflows.healthCardTitle">${escapeHtml(t('workflows.healthCardTitle'))}</span>
            <button id="btn-refresh-health" class="btn btn-ghost btn-sm" data-i18n="workflows.btnRefreshHealth">${escapeHtml(t('workflows.btnRefreshHealth'))}</button>
          </div>
          <div id="health-stats-container">
            <div class="stat-grid">
              <div class="stat-card">
                <div class="stat-label" data-i18n="workflows.statTotalRuns">${escapeHtml(t('workflows.statTotalRuns'))}</div>
                <div class="stat-value" id="health-total-runs">-</div>
                <div class="stat-sub" id="health-success-detail">-</div>
              </div>
              <div class="stat-card">
                <div class="stat-label" data-i18n="workflows.statSuccessRate">${escapeHtml(t('workflows.statSuccessRate'))}</div>
                <div class="stat-value" id="health-success-rate">-</div>
                <div class="stat-sub" id="health-approval-rejected">-</div>
              </div>
              <div class="stat-card">
                <div class="stat-label" data-i18n="workflows.statAvgDuration">${escapeHtml(t('workflows.statAvgDuration'))}</div>
                <div class="stat-value" id="health-avg-duration">-</div>
                <div class="stat-sub" id="health-tokens-stat">${escapeHtml(t('workflows.statTokensUnavailable'))}</div>
              </div>
            </div>
          </div>
        </div>
      `;

      loadHealthData();
      document.getElementById('btn-refresh-health').addEventListener('click', loadHealthData);
    }
  }

  async function loadHealthData() {
    try {
      const h = await callBridge('workflows.health', state.currentProject ? { id: undefined, project: state.currentProject } : {});
      if (h) {
        const elRuns = document.getElementById('health-total-runs');
        const elDetail = document.getElementById('health-success-detail');
        const elRate = document.getElementById('health-success-rate');
        const elRej = document.getElementById('health-approval-rejected');
        const elDur = document.getElementById('health-avg-duration');
        const elTok = document.getElementById('health-tokens-stat');

        if (elRuns) {
          if (h.runs !== undefined && h.runs !== null) {
            setElementDescriptor(elRuns, formatNumber(h.runs));
          } else {
            setElementDescriptor(elRuns, { key: 'common.none' });
          }
        }
        if (elDetail) {
          if (h.successes !== undefined && h.failures !== undefined) {
            setElementDescriptor(elDetail, { key: 'workflows.statSuccessDetail', params: { successes: h.successes, failures: h.failures } });
          } else {
            setElementDescriptor(elDetail, '');
          }
        }
        if (elRate) {
          if (h.successRate !== null && h.successRate !== undefined) {
            setElementDescriptor(elRate, (h.successRate * 100).toFixed(1) + '%');
          } else {
            setElementDescriptor(elRate, { key: 'common.none' });
          }
        }
        if (elRej) {
          if (h.approvalRejected !== undefined) {
            setElementDescriptor(elRej, { key: 'workflows.statApprovalRejected', params: { count: h.approvalRejected } });
          } else {
            setElementDescriptor(elRej, '');
          }
        }
        if (elDur) {
          if (h.averageDurationMs !== null && h.averageDurationMs !== undefined) {
            setElementDescriptor(elDur, Math.round(h.averageDurationMs) + 'ms');
          } else {
            setElementDescriptor(elDur, { key: 'common.none' });
          }
        }
        if (elTok) {
          if (h.tokensAvailable && h.tokens !== null) {
            setElementDescriptor(elTok, { key: 'workflows.statTokens', params: { tokens: formatNumber(h.tokens) } });
          } else {
            setElementDescriptor(elTok, { key: 'workflows.statTokensUnavailable' });
          }
        }
      }
    } catch {
      const elRuns = document.getElementById('health-total-runs');
      const elRate = document.getElementById('health-success-rate');
      const elDur = document.getElementById('health-avg-duration');
      if (elRuns) setElementDescriptor(elRuns, { key: 'common.none' });
      if (elRate) setElementDescriptor(elRate, { key: 'common.none' });
      if (elDur) setElementDescriptor(elDur, { key: 'common.none' });
    }
  }

  function getRunStateBadge(st) {
    switch (st) {
      case 'Completed':
      case 'Success':
        return `<span class="status-badge status-sage" data-i18n="workflows.stateSuccess">${escapeHtml(t('workflows.stateSuccess'))}</span>`;
      case 'Running':
        return `<span class="status-badge status-amber" data-i18n="workflows.stateRunning">${escapeHtml(t('workflows.stateRunning'))}</span>`;
      case 'Failed':
      case 'Error':
        return `<span class="status-badge status-red" data-i18n="workflows.stateFailed">${escapeHtml(t('workflows.stateFailed'))}</span>`;
      case 'Pending Approval':
        return `<span class="status-badge status-amber" data-i18n="workflows.statePendingApproval">${escapeHtml(t('workflows.statePendingApproval'))}</span>`;
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(st || t('common.unknown'))}</span>`;
    }
  }

  async function openRunDetail(runId) {
    state.selectedRunId = runId;
    openDrawer({ key: 'workflows.loadingRunDetail' }, { key: 'workflows.runAudit' });

    try {
      const run = await callBridge('runs.get', { id: runId });
      if (!run) {
        const e = new Error('workflows.runNotFound');
        e.i18nKey = 'workflows.runNotFound';
        throw e;
      }

      const runSub = run.id ? { key: 'workflows.runSubtitle', params: { id: run.id.substring(0, 8) } } : { key: 'workflows.runAudit' };
      setDrawerTitle(run.title ? run.title : { key: 'workflows.runDetail' }, runSub);
      setDrawerCustomActions(`
        <button id="btn-drawer-replay" class="btn btn-secondary btn-sm" data-i18n="workflows.btnReplayRun">${escapeHtml(t('workflows.btnReplayRun'))}</button>
      `);

      document.getElementById('btn-drawer-replay').addEventListener('click', async () => {
        try {
          await callBridge('workflows.replay', { runId: run.id });
          showToast({ key: 'workflows.replaySubmittedToast' });
          closeDrawer();
          await refreshDashboard(true, true);
        } catch (e) {
          showToast({ key: 'workflows.replayFailedToast', params: { error: e.message } }, 'error');
        }
      });

      const steps = run.steps || [];
      const drawerBody = document.getElementById('drawer-content');

      drawerBody.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title" data-i18n="workflows.basicInfo">${escapeHtml(t('workflows.basicInfo'))}</span>
            ${getRunStateBadge(run.state)}
          </div>
          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 11px;">
            <div><span class="text-secondary" data-i18n="workflows.metaMode">${escapeHtml(t('workflows.metaMode'))}</span> <strong>${run.dryRun ? t('workflows.modeDryRunLabel') : t('workflows.modeActualLabel')}</strong></div>
            <div><span class="text-secondary" data-i18n="workflows.metaVersion">${escapeHtml(t('workflows.metaVersion'))}</span> v${escapeHtml(String(run.workflowVersion || 1))}</div>
            <div><span class="text-secondary" data-i18n="workflows.metaDuration">${escapeHtml(t('workflows.metaDuration'))}</span> ${run.durationMs ? escapeHtml(String(run.durationMs)) + 'ms' : '-'}</div>
            <div><span class="text-secondary" data-i18n="workflows.metaTriggerTime">${escapeHtml(t('workflows.metaTriggerTime'))}</span> ${formatTime(run.startedAt)}</div>
          </div>
        </div>

        <div>
          <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;" data-i18n="workflows.executionSteps" data-i18n-params="${escapeHtml(JSON.stringify({ count: steps.length }))}">${escapeHtml(t('workflows.executionSteps', { count: steps.length }))}</h3>
          <div style="display: flex; flex-direction: column; gap: 10px;">
            ${steps.map((step, idx) => `
              <div class="card" style="margin-bottom: 0; padding: 10px 12px;">
                <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
                  <div>
                    <strong>${idx + 1}. ${escapeHtml(step.title || t('workflows.defaultStepTitle'))}</strong>
                    <span class="code-badge" style="margin-left: 6px;">${escapeHtml(step.tool || '')}</span>
                  </div>
                  <div style="display: flex; align-items: center; gap: 6px;">
                    ${step.durationMs ? `<span style="font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(String(step.durationMs))}ms</span>` : ''}
                    ${getRunStateBadge(step.state)}
                  </div>
                </div>
                ${step.output ? `
                  <div class="code-view" style="max-height: 160px; font-size: 12px;">${escapeHtml(typeof step.output === 'string' ? step.output : JSON.stringify(step.output, null, 2))}</div>
                ` : `<div style="font-size: 12px; color: var(--text-muted);" data-i18n="workflows.noOutput">${escapeHtml(t('workflows.noOutput'))}</div>`}
              </div>
            `).join('')}
          </div>
        </div>
      `;
    } catch (err) {
      setDrawerTitle({ key: 'common.loadFailed' }, { key: 'common.error' });
      const drawerContent = document.getElementById('drawer-content');
      if (drawerContent) {
        if (err && err.i18nKey) {
          drawerContent.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="workflows.fetchRunFailedPrefix">${escapeHtml(t('workflows.fetchRunFailedPrefix'))}</span><span data-i18n="${err.i18nKey}">${escapeHtml(t(err.i18nKey))}</span>
            </div>
          `;
        } else {
          drawerContent.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="workflows.fetchRunFailedPrefix">${escapeHtml(t('workflows.fetchRunFailedPrefix'))}</span><span>${escapeHtml(err ? err.message : String(err))}</span>
            </div>
          `;
        }
      }
    }
  }

  function openWorkflowPromptBuilderModal() {
    const modalBody = `
      <div class="alert-banner alert-info">
        <span data-i18n="workflows.builderNotice">${escapeHtml(t('workflows.builderNotice'))}</span>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="workflows.targetProjectLabel">${escapeHtml(t('workflows.targetProjectLabel'))}</label>
        <select id="wf-build-project" class="form-select">
          ${state.registeredProjects.map(p => `
            <option value="${escapeHtml(p.path || p.id)}" ${(state.currentProject === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
          `).join('')}
        </select>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="workflows.promptDescLabel">${escapeHtml(t('workflows.promptDescLabel'))}</label>
        <textarea id="wf-build-desc" class="form-textarea" data-i18n-placeholder="workflows.promptDescPlaceholder" placeholder="${escapeHtml(t('workflows.promptDescPlaceholder'))}"></textarea>
      </div>
    `;

    openModal({ key: 'workflows.builderModalTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-wf-build" data-i18n="common.cancel">${escapeHtml(t('common.cancel'))}</button>
      <button class="btn btn-primary" id="btn-confirm-wf-build" data-i18n="workflows.btnGenerateDraft">${escapeHtml(t('workflows.btnGenerateDraft'))}</button>
    `);

    document.getElementById('btn-cancel-wf-build').addEventListener('click', closeModal);
    document.getElementById('btn-confirm-wf-build').addEventListener('click', async () => {
      const project = document.getElementById('wf-build-project').value;
      const description = document.getElementById('wf-build-desc').value.trim();

      if (!project) {
        showToast({ key: 'workflows.selectProjectFirst' }, 'error');
        return;
      }
      if (!description) {
        showToast({ key: 'workflows.enterDescFirst' }, 'error');
        return;
      }

      try {
        const res = await callBridge('workflows.build', { project, description });
        closeModal();

        if (res && res.workflow) {
          showToast(res.message || { key: 'workflows.draftGeneratedToast' });
          // Load draft into editor
          openEditWorkflowModal(res.workflow, res.unresolvedInputs || []);
        }
      } catch (err) {
        showToast({ key: 'workflows.buildFailedToast', params: { error: err.message } }, 'error');
      }
    });
  }

  function openEditWorkflowModal(wf = null, unresolvedInputs = []) {
    const isEdit = !!(wf && wf.id);
    const defaultSteps = [
      {
        id: 'step-1',
        title: '检查工作区状态',
        tool: 'git.status',
        arguments: {}
      },
      {
        id: 'step-2',
        title: '运行单元测试',
        tool: 'shell.test',
        arguments: { executable: 'npm', args: ['test'], timeoutSeconds: 60 }
      }
    ];

    let steps = wf && wf.steps ? JSON.parse(JSON.stringify(wf.steps)) : defaultSteps;

    const modalBody = `
      ${unresolvedInputs && unresolvedInputs.length > 0 ? `
        <div class="alert-banner alert-warning">
          <span>${escapeHtml(t('workflows.unresolvedParamsPrefix', { params: unresolvedInputs.join('、') }))}</span>
        </div>
      ` : ''}
      <div class="form-group">
        <label class="form-label" data-i18n="workflows.titleLabel">${escapeHtml(t('workflows.titleLabel'))}</label>
        <input type="text" id="wf-modal-title" class="form-input" value="${escapeHtml(wf ? wf.title : t('workflows.defaultTitle'))}" data-i18n-placeholder="workflows.titlePlaceholder" placeholder="${escapeHtml(t('workflows.titlePlaceholder'))}">
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="workflows.projectLabel">${escapeHtml(t('workflows.projectLabel'))}</label>
        <select id="wf-modal-project" class="form-select">
          ${state.registeredProjects.map(p => `
            <option value="${escapeHtml(p.path || p.id)}" ${(wf && wf.project === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
          `).join('')}
        </select>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="workflows.descLabel">${escapeHtml(t('workflows.descLabel'))}</label>
        <input type="text" id="wf-modal-desc" class="form-input" value="${escapeHtml(wf ? wf.description || '' : t('workflows.defaultDesc'))}" data-i18n-placeholder="workflows.descPlaceholder" placeholder="${escapeHtml(t('workflows.descPlaceholder'))}">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="workflows.triggerLabel">${escapeHtml(t('workflows.triggerLabel'))}</label>
          <select id="wf-modal-trigger" class="form-select">
            <option value="manual" ${(wf && wf.trigger === 'manual') ? 'selected' : ''}>manual (手动运行)</option>
            <option value="cron" ${(wf && wf.trigger === 'cron') ? 'selected' : ''}>cron (定时周期)</option>
            <option value="app_start" ${(wf && wf.trigger === 'app_start') ? 'selected' : ''}>app_start (应用启动)</option>
            <option value="session_completed" ${(wf && wf.trigger === 'session_completed') ? 'selected' : ''}>session_completed (会话结束)</option>
            <option value="git_event" ${(wf && wf.trigger === 'git_event') ? 'selected' : ''}>git_event (Git 变更)</option>
            <option value="usage_reset" ${(wf && wf.trigger === 'usage_reset') ? 'selected' : ''}>usage_reset (用量重置)</option>
          </select>
        </div>
        <div class="form-group" id="wf-cron-group">
          <label class="form-label" data-i18n="workflows.cronLabel">${escapeHtml(t('workflows.cronLabel'))}</label>
          <input type="text" id="wf-modal-cron" class="form-input" value="${escapeHtml(wf ? wf.cron || '' : '0 * * * *')}" placeholder="*/30 * * * *">
        </div>
      </div>

      <div style="margin-top: 6px;">
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
          <label class="form-label" style="margin-bottom: 0;" data-i18n="workflows.stepsLabel">${escapeHtml(t('workflows.stepsLabel'))}</label>
          <button type="button" id="btn-add-step" class="btn btn-ghost btn-sm" data-i18n="workflows.btnAddStep">${escapeHtml(t('workflows.btnAddStep'))}</button>
        </div>
        <div id="wf-steps-list" style="display: flex; flex-direction: column; gap: 8px; max-height: 240px; overflow-y: auto;"></div>
      </div>
    `;

    openModal({ key: isEdit ? 'workflows.editModalTitle' : 'workflows.newModalTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-wf" data-i18n="common.cancel">${escapeHtml(t('common.cancel'))}</button>
      <button class="btn btn-primary" id="btn-save-wf" data-i18n="workflows.btnSaveWorkflow">${escapeHtml(t('workflows.btnSaveWorkflow'))}</button>
    `);

    const renderSteps = () => {
      const container = document.getElementById('wf-steps-list');
      if (!container) return;
      container.innerHTML = steps.map((s, idx) => `
        <div class="card" style="padding: 8px 10px; margin-bottom: 0; background: var(--bg-subtle);">
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
            <input type="text" class="form-input wf-step-title" data-idx="${idx}" value="${escapeHtml(s.title || '')}" data-i18n-placeholder="workflows.stepTitlePlaceholder" placeholder="${escapeHtml(t('workflows.stepTitlePlaceholder'))}" style="width: 160px; font-size: 11px; padding: 2px 6px;">
            <select class="form-select wf-step-tool" data-idx="${idx}" style="font-size: 11px; padding: 2px 6px;">
              <option value="git.status" ${s.tool === 'git.status' ? 'selected' : ''}>git.status (只读)</option>
              <option value="git.diff" ${s.tool === 'git.diff' ? 'selected' : ''}>git.diff (只读)</option>
              <option value="git.log" ${s.tool === 'git.log' ? 'selected' : ''}>git.log (只读)</option>
              <option value="shell.test" ${s.tool === 'shell.test' ? 'selected' : ''}>shell.test (需要审批)</option>
              <option value="shell.typecheck" ${s.tool === 'shell.typecheck' ? 'selected' : ''}>shell.typecheck (需要审批)</option>
              <option value="file.write" ${s.tool === 'file.write' ? 'selected' : ''}>file.write (需要审批)</option>
              <option value="agent.run" ${s.tool === 'agent.run' ? 'selected' : ''}>agent.run (需要审批)</option>
            </select>
            <div style="display: flex; gap: 2px;">
              <button type="button" class="btn-icon-subtle btn-step-up" data-idx="${idx}" data-i18n-title="workflows.btnStepUp" title="${escapeHtml(t('workflows.btnStepUp'))}">↑</button>
              <button type="button" class="btn-icon-subtle btn-step-down" data-idx="${idx}" data-i18n-title="workflows.btnStepDown" title="${escapeHtml(t('workflows.btnStepDown'))}">↓</button>
              <button type="button" class="btn-icon-subtle btn-step-del" data-idx="${idx}" data-i18n-title="workflows.btnStepDel" title="${escapeHtml(t('workflows.btnStepDel'))}" style="color: var(--status-red-text);">×</button>
            </div>
          </div>
          <div>
            <textarea class="form-textarea code-editor wf-step-args" data-idx="${idx}" style="min-height: 56px; font-size: 12px; padding: 6px 8px;" placeholder="${s.tool === 'agent.run' ? escapeHtml(t('workflows.stepArgsAgentPlaceholder')) : escapeHtml(t('workflows.stepArgsPlaceholder'))}">${escapeHtml(typeof s.arguments === 'object' ? JSON.stringify(s.arguments, null, 2) : s.arguments || '{}')}</textarea>
            ${s.tool === 'agent.run' ? `<div style="font-size: 12px; color: var(--text-secondary); margin-top: 4px;" data-i18n="workflows.agentRunNotice">${escapeHtml(t('workflows.agentRunNotice'))}</div>` : ''}
          </div>
        </div>
      `).join('');

      container.querySelectorAll('.wf-step-title').forEach(inp => {
        inp.addEventListener('input', (e) => {
          steps[parseInt(inp.getAttribute('data-idx'), 10)].title = e.target.value;
        });
      });

      container.querySelectorAll('.wf-step-tool').forEach(sel => {
        sel.addEventListener('change', (e) => {
          const idx = parseInt(sel.getAttribute('data-idx'), 10);
          const tool = e.target.value;
          steps[idx].tool = tool;
          if (tool === 'shell.test') {
            steps[idx].arguments = { executable: 'npm', args: ['test'], timeoutSeconds: 60 };
          } else if (tool === 'shell.typecheck') {
            steps[idx].arguments = { executable: 'npm', args: ['run', 'typecheck'], timeoutSeconds: 60 };
          } else if (tool === 'file.write') {
            steps[idx].arguments = { path: 'relative.txt', content: '...' };
          } else if (tool === 'agent.run') {
            steps[idx].arguments = { executable: '', args: [], timeoutSeconds: 120 };
          } else {
            steps[idx].arguments = {};
          }
          renderSteps();
        });
      });

      container.querySelectorAll('.wf-step-args').forEach(tx => {
        tx.addEventListener('change', (e) => {
          const idx = parseInt(tx.getAttribute('data-idx'), 10);
          try {
            steps[idx].arguments = JSON.parse(e.target.value);
          } catch {
            steps[idx].arguments = e.target.value;
          }
        });
      });

      container.querySelectorAll('.btn-step-up').forEach(btn => {
        btn.addEventListener('click', () => {
          const idx = parseInt(btn.getAttribute('data-idx'), 10);
          if (idx > 0) {
            const temp = steps[idx];
            steps[idx] = steps[idx - 1];
            steps[idx - 1] = temp;
            renderSteps();
          }
        });
      });

      container.querySelectorAll('.btn-step-down').forEach(btn => {
        btn.addEventListener('click', () => {
          const idx = parseInt(btn.getAttribute('data-idx'), 10);
          if (idx < steps.length - 1) {
            const temp = steps[idx];
            steps[idx] = steps[idx + 1];
            steps[idx + 1] = temp;
            renderSteps();
          }
        });
      });

      container.querySelectorAll('.btn-step-del').forEach(btn => {
        btn.addEventListener('click', () => {
          const idx = parseInt(btn.getAttribute('data-idx'), 10);
          steps.splice(idx, 1);
          renderSteps();
        });
      });
    };

    renderSteps();

    document.getElementById('btn-add-step').addEventListener('click', () => {
      steps.push({
        id: 'step-' + (steps.length + 1),
        title: t('workflows.newStepDefaultTitle'),
        tool: 'git.status',
        arguments: {}
      });
      renderSteps();
    });

    document.getElementById('btn-cancel-wf').addEventListener('click', closeModal);
    document.getElementById('btn-save-wf').addEventListener('click', async () => {
      const title = document.getElementById('wf-modal-title').value.trim();
      const project = document.getElementById('wf-modal-project').value;
      const description = document.getElementById('wf-modal-desc').value.trim();
      const trigger = document.getElementById('wf-modal-trigger').value;
      const cron = document.getElementById('wf-modal-cron').value.trim();

      if (!title) {
        showToast({ key: 'workflows.titleRequired' }, 'error');
        return;
      }
      if (!project) {
        showToast({ key: 'workflows.projectRequired' }, 'error');
        return;
      }

      for (const s of steps) {
        if (typeof s.arguments === 'string') {
          try {
            s.arguments = JSON.parse(s.arguments);
          } catch {
            showToast({ key: 'workflows.invalidArgsJson', params: { title: s.title } }, 'error');
            return;
          }
        }
        if (['agent.run', 'shell.test', 'shell.typecheck'].includes(s.tool)) {
          const argsObj = s.arguments;
          if (!argsObj || typeof argsObj !== 'object' || Array.isArray(argsObj)) {
            showToast({ key: 'workflows.argsMustBeObject', params: { title: s.title } }, 'error');
            return;
          }
          if (typeof argsObj.executable !== 'string' || !argsObj.executable.trim()) {
            showToast({ key: 'workflows.executableRequired', params: { title: s.title, tool: s.tool } }, 'error');
            return;
          }
          if (!Array.isArray(argsObj.args) || !argsObj.args.every(a => typeof a === 'string')) {
            showToast({ key: 'workflows.argsMustBeStringArray', params: { title: s.title, tool: s.tool } }, 'error');
            return;
          }
        }
      }

      const payload = {
        id: (wf && wf.id) ? wf.id : undefined,
        title,
        project,
        description,
        trigger,
        cron: trigger === 'cron' ? cron : undefined,
        enabled: wf ? wf.enabled : true,
        guidelines: wf?.guidelines || [],
        steps
      };

      try {
        await callBridge('workflows.save', payload);
        showToast({ key: 'workflows.savedToast' });
        closeModal();
        await refreshDashboard(true, true);
      } catch (err) {
        showToast({ key: 'workflows.saveFailedToast', params: { error: err.message } }, 'error');
      }
    });
  }

  // -------------------------------------------------------------------------
  // 3. SETUP VIEW (Complete Memory lifecycle, Guidelines editor, Library URL/Path)
  // -------------------------------------------------------------------------
  function renderSetupView(container) {
    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="setupL.header.title">${escapeHtml(t('setupL.header.title'))}</h1>
          <p data-i18n="setupL.header.desc">${escapeHtml(t('setupL.header.desc'))}</p>
        </div>
        <div class="page-actions">
          <button id="btn-scan-setup" class="btn btn-secondary btn-sm" data-i18n="setupL.actions.scan">${escapeHtml(t('setupL.actions.scan'))}</button>
          <button id="btn-audit-setup" class="btn btn-secondary btn-sm" data-i18n="setupL.actions.audit">${escapeHtml(t('setupL.actions.audit'))}</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.setupActiveTab === 'rules' ? 'active' : ''}" data-setuptab="rules" data-i18n="setupL.tabs.rules">${escapeHtml(t('setupL.tabs.rules'))}</button>
        <button class="tab-btn ${state.setupActiveTab === 'skills' ? 'active' : ''}" data-setuptab="skills" data-i18n="setupL.tabs.skills">${escapeHtml(t('setupL.tabs.skills'))}</button>
        <button class="tab-btn ${state.setupActiveTab === 'hooks' ? 'active' : ''}" data-setuptab="hooks" data-i18n="setupL.tabs.hooks">${escapeHtml(t('setupL.tabs.hooks'))}</button>
        <button class="tab-btn ${state.setupActiveTab === 'mcp' ? 'active' : ''}" data-setuptab="mcp" data-i18n="setupL.tabs.mcp">${escapeHtml(t('setupL.tabs.mcp'))}</button>
        <button class="tab-btn ${state.setupActiveTab === 'guidelines' ? 'active' : ''}" data-setuptab="guidelines" data-i18n="setupL.tabs.guidelines">${escapeHtml(t('setupL.tabs.guidelines'))}</button>
        <button class="tab-btn ${state.setupActiveTab === 'memory' ? 'active' : ''}" data-setuptab="memory" data-i18n="setupL.tabs.memory">${escapeHtml(t('setupL.tabs.memory'))}</button>
        <button class="tab-btn ${state.setupActiveTab === 'library' ? 'active' : ''}" data-setuptab="library" data-i18n="setupL.tabs.library">${escapeHtml(t('setupL.tabs.library'))}</button>
      </div>

      <div id="setup-tab-content"></div>
    `;

    container.querySelectorAll('[data-setuptab]').forEach(tab => {
      tab.addEventListener('click', () => {
        state.setupActiveTab = tab.getAttribute('data-setuptab');
        container.querySelectorAll('[data-setuptab]').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        renderSetupTabContent();
      });
    });

    document.getElementById('btn-scan-setup').addEventListener('click', async () => {
      try {
        await callBridge('setup.scan', state.currentProject ? { project: state.currentProject } : {});
        showToast({ key: 'setupL.toast.scanSuccess' });
        await refreshDashboard(true, true);
      } catch (e) {
        showToast({ key: 'setupL.toast.scanFailed', params: { error: e.message } }, 'error');
      }
    });

    document.getElementById('btn-audit-setup').addEventListener('click', async () => {
      try {
        const res = await callBridge('setup.audit', state.currentProject ? { project: state.currentProject } : {});
        const diag = (res && res.diagnostics) || [];
        if (diag.length === 0) {
          showToast({ key: 'setupL.toast.auditPassed' }, 'info');
        } else {
          showToast({ key: 'setupL.toast.auditWarning', params: { count: diag.length } }, 'warning');
        }
      } catch (e) {
        showToast({ key: 'setupL.toast.auditFailed', params: { error: e.message } }, 'error');
      }
    });

    renderSetupTabContent();
  }

  function renderSetupTabContent() {
    const target = document.getElementById('setup-tab-content');
    if (!target) return;

    if (state.setupActiveTab === 'memory') {
      renderMemorySection(target);
    } else if (state.setupActiveTab === 'guidelines') {
      renderGuidelinesSection(target);
    } else if (state.setupActiveTab === 'library') {
      renderLibrarySection(target);
    } else if (state.setupActiveTab === 'mcp') {
      renderMcpSection(target);
    } else {
      renderArtifactsSection(target, state.setupActiveTab);
    }
  }

  function renderArtifactsSection(target, typeName) {
    const artifacts = (state.dashboard && state.dashboard.artifacts) || [];
    const filtered = artifacts.filter(a => {
      const t = (a.type || '').toLowerCase();
      if (typeName === 'rules') return t === 'instruction' || t === 'rule';
      if (typeName === 'skills') return t === 'skill' || t === 'command';
      if (typeName === 'hooks') return a.containsHooks === true || t === 'hook';
      if (typeName === 'mcp') return t === 'mcp' || a.containsMCP === true;
      if (typeName === 'configurations') return t === 'configuration';
      return t === typeName.toLowerCase();
    });

    target.innerHTML = `
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
        <span class="text-secondary" style="font-size: 13px;" data-i18n="setupL.artifacts.countSummary" data-i18n-params="${escapeHtml(JSON.stringify({ count: filtered.length, type: typeName }))}">${escapeHtml(t('setupL.artifacts.countSummary', { count: filtered.length, type: typeName }))}</span>
      </div>

      ${filtered.length === 0 ? `
        <div class="empty-state">
          <div class="empty-state-title" data-i18n="setupL.artifacts.emptyTitle" data-i18n-params="${escapeHtml(JSON.stringify({ type: typeName }))}">${escapeHtml(t('setupL.artifacts.emptyTitle', { type: typeName }))}</div>
          <div class="empty-state-desc" data-i18n="setupL.artifacts.emptyDesc">${escapeHtml(t('setupL.artifacts.emptyDesc'))}</div>
        </div>
      ` : `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th data-i18n="setupL.table.titleOrId">${escapeHtml(t('setupL.table.titleOrId'))}</th>
                <th data-i18n="setupL.table.providerOrScope">${escapeHtml(t('setupL.table.providerOrScope'))}</th>
                <th data-i18n="setupL.table.estimatedTokens">${escapeHtml(t('setupL.table.estimatedTokens'))}</th>
                <th data-i18n="setupL.table.hash">${escapeHtml(t('setupL.table.hash'))}</th>
                <th data-i18n="setupL.table.diagnostics">${escapeHtml(t('setupL.table.diagnostics'))}</th>
                <th style="text-align: right; width: 140px;" data-i18n="setupL.table.actions">${escapeHtml(t('setupL.table.actions'))}</th>
              </tr>
            </thead>
            <tbody>
              ${filtered.map(a => `
                <tr>
                  <td>
                    <strong>${escapeHtml(a.title || a.id)}</strong>
                    <div style="font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(a.path || '')}</div>
                  </td>
                  <td>
                    <span class="code-badge">${escapeHtml(a.provider || 'generic')}</span>
                    <span style="font-size: 12px; color: var(--text-secondary); margin-left: 4px;">${escapeHtml(a.scope || 'project')}</span>
                  </td>
                  <td><span class="font-mono">${escapeHtml(String(a.tokens || '-'))}</span></td>
                  <td><span class="font-mono" style="font-size: 12px;">${a.hash ? escapeHtml(a.hash.substring(0, 10)) : '-'}</span></td>
                  <td>
                    ${a.diagnostics && a.diagnostics.length > 0
                      ? `<span class="status-badge status-amber" data-i18n="setupL.artifacts.warningCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: a.diagnostics.length }))}">${escapeHtml(t('setupL.artifacts.warningCount', { count: a.diagnostics.length }))}</span>`
                      : `<span class="status-badge status-sage" data-i18n="setupL.artifacts.statusNormal">${escapeHtml(t('setupL.artifacts.statusNormal'))}</span>`}
                  </td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-preview-artifact" data-id="${escapeHtml(a.id)}" data-i18n="setupL.artifacts.preview">${escapeHtml(t('setupL.artifacts.preview'))}</button>
                    ${a.path ? `<button class="btn btn-ghost btn-sm btn-reveal-path" data-path="${escapeHtml(a.path)}" data-i18n="setupL.artifacts.reveal">${escapeHtml(t('setupL.artifacts.reveal'))}</button>` : ''}
                  </td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      `}
    `;

    target.querySelectorAll('.btn-preview-artifact').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        const art = filtered.find(a => a.id === id);
        if (art) {
          openDrawer(art.title || { key: 'setupL.artifacts.drawerTitle' }, art.path);
          document.getElementById('drawer-content').innerHTML = `
            <div class="card">
              <div class="card-header"><span class="card-title" data-i18n="setupL.drawer.basicInfo">${escapeHtml(t('setupL.drawer.basicInfo'))}</span></div>
              <div style="font-size: 12px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                <div><span class="text-secondary" data-i18n="setupL.drawer.type">${escapeHtml(t('setupL.drawer.type'))}</span> ${escapeHtml(art.type)}</div>
                <div><span class="text-secondary" data-i18n="setupL.drawer.provider">${escapeHtml(t('setupL.drawer.provider'))}</span> ${escapeHtml(art.provider)}</div>
                <div><span class="text-secondary" data-i18n="setupL.drawer.tokens">${escapeHtml(t('setupL.drawer.tokens'))}</span> ${escapeHtml(String(art.tokens || '-'))}</div>
                <div><span class="text-secondary" data-i18n="setupL.drawer.hash">${escapeHtml(t('setupL.drawer.hash'))}</span> <span class="font-mono">${escapeHtml(art.hash || '-')}</span></div>
              </div>
              <div style="margin-top: 8px; font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);"><span data-i18n="setupL.drawer.pathPrefix">${escapeHtml(t('setupL.drawer.pathPrefix'))}</span>: ${escapeHtml(art.path || '-')}</div>
            </div>
            <div>
              <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;" data-i18n="setupL.drawer.readonlyPreview">${escapeHtml(t('setupL.drawer.readonlyPreview'))}</h3>
              <div class="code-view">${art.content ? escapeHtml(art.content) : tHtml('setupL.drawer.noContent')}</div>
            </div>
          `;
        }
      });
    });

    target.querySelectorAll('.btn-reveal-path').forEach(btn => {
      btn.addEventListener('click', async () => {
        const path = btn.getAttribute('data-path');
        try {
          await callBridge('system.reveal', { path });
        } catch (e) {
          showToast({ key: 'setupL.toast.revealFailed', params: { error: e.message } }, 'error');
        }
      });
    });
  }

  // --- Real Guidelines Management (guidelines.list, guidelines.save) ---
  async function renderGuidelinesSection(target) {
    const thisGen = renderGeneration;
    const thisPage = state.currentPage;
    const thisScope = state.currentProject;

    target.innerHTML = `
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
        <span class="text-secondary" style="font-size: 12px;" data-i18n="setupL.guidelines.headerDesc">${escapeHtml(t('setupL.guidelines.headerDesc'))}</span>
        <button id="btn-new-guideline" class="btn btn-primary btn-sm" data-i18n="setupL.guidelines.btnNew">${escapeHtml(t('setupL.guidelines.btnNew'))}</button>
      </div>
      <div id="guidelines-list-container">
        <div class="text-secondary" style="font-size: 12px; padding: 20px 0;" data-i18n="setupL.common.loading">${escapeHtml(t('setupL.common.loading'))}</div>
      </div>
    `;

    document.getElementById('btn-new-guideline').addEventListener('click', () => openCreateOrEditGuidelineModal());

    try {
      const guidelines = await callBridge('guidelines.list', state.currentProject ? { project: state.currentProject } : {});
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(target)) return;
      const list = Array.isArray(guidelines) ? guidelines : [];
      const cont = document.getElementById('guidelines-list-container');
      if (!cont) return;

      if (list.length === 0) {
        cont.innerHTML = `
          <div class="empty-state">
            <div class="empty-state-title" data-i18n="setupL.guidelines.emptyTitle">${escapeHtml(t('setupL.guidelines.emptyTitle'))}</div>
            <div class="empty-state-desc" data-i18n="setupL.guidelines.emptyDesc">${escapeHtml(t('setupL.guidelines.emptyDesc'))}</div>
            <button id="btn-empty-add-gl" class="btn btn-primary btn-sm" style="margin-top: 12px;" data-i18n="setupL.guidelines.btnCreate">${escapeHtml(t('setupL.guidelines.btnCreate'))}</button>
          </div>
        `;
        document.getElementById('btn-empty-add-gl').addEventListener('click', () => openCreateOrEditGuidelineModal());
        return;
      }

      cont.innerHTML = `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th data-i18n="setupL.guidelines.tableTitle">${escapeHtml(t('setupL.guidelines.tableTitle'))}</th>
                <th data-i18n="setupL.guidelines.tableScope">${escapeHtml(t('setupL.guidelines.tableScope'))}</th>
                <th data-i18n="setupL.guidelines.tableProject">${escapeHtml(t('setupL.guidelines.tableProject'))}</th>
                <th data-i18n="setupL.guidelines.tableUpdated">${escapeHtml(t('setupL.guidelines.tableUpdated'))}</th>
                <th style="text-align: right; width: 140px;" data-i18n="setupL.table.actions">${escapeHtml(t('setupL.table.actions'))}</th>
              </tr>
            </thead>
            <tbody>
              ${list.map(g => `
                <tr>
                  <td><strong>${escapeHtml(g.title || g.id)}</strong></td>
                  <td><span class="code-badge">${escapeHtml(g.scope || 'project')}</span></td>
                  <td style="font-size: 11px; color: var(--text-secondary);">${g.project ? escapeHtml(g.project.split('/').pop()) : tHtml('setupL.scope.global')}</td>
                  <td style="font-size: 11px; color: var(--text-secondary);">${formatTime(g.updatedAt || g.createdAt)}</td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-view-gl" data-id="${escapeHtml(g.id)}" data-i18n="setupL.common.view">${escapeHtml(t('setupL.common.view'))}</button>
                    <button class="btn btn-ghost btn-sm btn-edit-gl" data-id="${escapeHtml(g.id)}" data-i18n="setupL.common.edit">${escapeHtml(t('setupL.common.edit'))}</button>
                  </td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      `;

      cont.querySelectorAll('.btn-view-gl').forEach(btn => {
        btn.addEventListener('click', () => {
          const id = btn.getAttribute('data-id');
          const g = list.find(item => item.id === id);
          if (g) {
            openDrawer(g.title || { key: 'setupL.guidelines.drawerTitle' }, g.id);
            document.getElementById('drawer-content').innerHTML = `
              <div class="card">
                <div class="card-header">
                  <span class="card-title" data-i18n="setupL.drawer.basicInfo">${escapeHtml(t('setupL.drawer.basicInfo'))}</span>
                  <span class="status-badge status-neutral" data-i18n="setupL.guidelines.badgeSnapshot">${escapeHtml(t('setupL.guidelines.badgeSnapshot'))}</span>
                </div>
                <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
                  <div><span class="text-secondary" data-i18n="setupL.guidelines.scopeLabel">${escapeHtml(t('setupL.guidelines.scopeLabel'))}</span> ${escapeHtml(g.scope || 'project')}</div>
                  <div><span class="text-secondary" data-i18n="setupL.guidelines.projectLabel">${escapeHtml(t('setupL.guidelines.projectLabel'))}</span> ${g.project ? escapeHtml(g.project) : tHtml('setupL.scope.global')}</div>
                  <div><span class="text-secondary" data-i18n="setupL.guidelines.modeLabel">${escapeHtml(t('setupL.guidelines.modeLabel'))}</span> <span data-i18n="setupL.guidelines.modeValue">${escapeHtml(t('setupL.guidelines.modeValue'))}</span></div>
                  <div><span class="text-secondary" data-i18n="setupL.guidelines.runtimeImpactLabel">${escapeHtml(t('setupL.guidelines.runtimeImpactLabel'))}</span> <span data-i18n="setupL.guidelines.runtimeImpactValue">${escapeHtml(t('setupL.guidelines.runtimeImpactValue'))}</span></div>
                </div>
              </div>
              <div>
                <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;" data-i18n="setupL.guidelines.contentTitle">${escapeHtml(t('setupL.guidelines.contentTitle'))}</h3>
                <div class="code-view">${escapeHtml(g.content || '')}</div>
              </div>
            `;
          }
        });
      });

      cont.querySelectorAll('.btn-edit-gl').forEach(btn => {
        btn.addEventListener('click', () => {
          const id = btn.getAttribute('data-id');
          const g = list.find(item => item.id === id);
          if (g) openCreateOrEditGuidelineModal(g);
        });
      });

    } catch (err) {
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(target)) return;
      const cont = document.getElementById('guidelines-list-container');
      if (cont) {
        cont.innerHTML = `
          <div class="alert-banner alert-danger">${tHtml('setupL.guidelines.loadFailed', { error: err.message })}</div>
        `;
      }
    }
  }

  function openCreateOrEditGuidelineModal(initial = null) {
    const isEdit = !!(initial && initial.id);
    const modalBody = `
      <div class="form-group">
        <label class="form-label" data-i18n="setupL.guidelines.modalTitleLabel">${escapeHtml(t('setupL.guidelines.modalTitleLabel'))}</label>
        <input type="text" id="gl-title" class="form-input" value="${escapeHtml(initial ? initial.title : '')}" placeholder="${escapeHtml(t('setupL.guidelines.modalTitlePlaceholder'))}" data-i18n-placeholder="setupL.guidelines.modalTitlePlaceholder">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="setupL.guidelines.modalScopeLabel">${escapeHtml(t('setupL.guidelines.modalScopeLabel'))}</label>
          <select id="gl-scope" class="form-select">
            <option value="project" ${(initial && initial.scope === 'project') ? 'selected' : ''} data-i18n="setupL.guidelines.scopeProject">${escapeHtml(t('setupL.guidelines.scopeProject'))}</option>
            <option value="global" ${(initial && initial.scope === 'global') ? 'selected' : ''} data-i18n="setupL.guidelines.scopeGlobal">${escapeHtml(t('setupL.guidelines.scopeGlobal'))}</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="setupL.guidelines.modalProjectLabel">${escapeHtml(t('setupL.guidelines.modalProjectLabel'))}</label>
          <select id="gl-project" class="form-select">
            <option value="" data-i18n="setupL.guidelines.projectNone">${escapeHtml(t('setupL.guidelines.projectNone'))}</option>
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}" ${(initial && initial.project === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="setupL.guidelines.modalContentLabel">${escapeHtml(t('setupL.guidelines.modalContentLabel'))}</label>
        <textarea id="gl-content" class="form-textarea code-editor" style="min-height: 140px;" placeholder="${escapeHtml(t('setupL.guidelines.modalContentPlaceholder'))}" data-i18n-placeholder="setupL.guidelines.modalContentPlaceholder">${escapeHtml(initial ? initial.content || '' : '')}</textarea>
      </div>
    `;

    openModal(isEdit ? { key: 'setupL.guidelines.modalEditTitle' } : { key: 'setupL.guidelines.modalCreateTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-gl" data-i18n="setupL.common.cancel">${escapeHtml(t('setupL.common.cancel'))}</button>
      <button class="btn btn-primary" id="btn-save-gl" data-i18n="setupL.guidelines.btnSave">${escapeHtml(t('setupL.guidelines.btnSave'))}</button>
    `);

    document.getElementById('btn-cancel-gl').addEventListener('click', closeModal);
    document.getElementById('btn-save-gl').addEventListener('click', async () => {
      const title = document.getElementById('gl-title').value.trim();
      const scope = document.getElementById('gl-scope').value;
      const project = document.getElementById('gl-project').value;
      const content = document.getElementById('gl-content').value.trim();

      if (!title || !content) {
        showToast({ key: 'setupL.guidelines.toastValidationEmpty' }, 'error');
        return;
      }

      try {
        await callBridge('guidelines.save', {
          id: isEdit ? initial.id : undefined,
          title,
          scope,
          project: project || undefined,
          content
        });
        showToast({ key: 'setupL.guidelines.toastSaved' });
        closeModal();
        renderGuidelinesSection(document.getElementById('setup-tab-content'));
      } catch (err) {
        showToast({ key: 'setupL.guidelines.toastSaveFailed', params: { error: err.message } }, 'error');
      }
    });
  }

  // ===========================================================================
  // REUSE FRAGMENT: Codex Memory Reuse, Provider Trust & Outcomes
  // ===========================================================================
  function isSafeNonNegativeInteger(val) {
    return typeof val === 'number' && Number.isSafeInteger(val) && val >= 0;
  }

  function formatSafeCount(val) {
    return isSafeNonNegativeInteger(val) ? val.toLocaleString() : '未提供';
  }

  function safeEscapeHtml(str) {
    if (typeof escapeHtml === 'function') {
      return escapeHtml(str);
    }
    if (str === null || str === undefined) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  function formatSafeTime(isoStr) {
    if (typeof formatTime === 'function') {
      return formatTime(isoStr);
    }
    if (!isoStr) return '-';
    try {
      const d = new Date(isoStr);
      if (!isNaN(d.getTime())) return d.toLocaleString();
    } catch {}
    return String(isoStr);
  }

  function isAlreadyInstalledHook(sugOrPreview) {
    if (!sugOrPreview) return false;
    const ops = sugOrPreview.operations || sugOrPreview.preview || [];
    return sugOrPreview.alreadyInstalled === true && Array.isArray(ops) && ops.length === 0;
  }

  function renderProviderTrustNotice(sugOrPreview, isApplied = false) {
    if (!sugOrPreview || !sugOrPreview.requiresProviderTrust) return '';
    const noticeKey = isApplied ? 'improve.providerTrustNoticeApplied' : 'improve.providerTrustNoticeUnapplied';

    return `
      <div class="alert-banner alert-warning" style="margin-top: 8px; font-size: 11px; line-height: 1.5; border-color: var(--status-amber-border); background-color: var(--status-amber-bg); color: var(--status-amber-text);" role="note">
        <div style="font-weight: 600; margin-bottom: 2px;" data-i18n="improve.providerTrustTitle">${t('improve.providerTrustTitle')}</div>
        <div data-i18n="${noticeKey}">
          ${tHtml(noticeKey)}
        </div>
      </div>
    `;
  }

  function renderAlreadyInstalledNotice(sugOrPreview) {
    if (!isAlreadyInstalledHook(sugOrPreview)) return '';
    return `
      <div class="alert-banner alert-neutral" style="margin-top: 8px; font-size: 11px; line-height: 1.5; border-color: var(--status-sage-border); background-color: var(--status-sage-bg); color: var(--status-sage-text);" role="note">
        <div style="font-weight: 600; margin-bottom: 2px;" data-i18n="improve.alreadyInstalledTitle">✓ ${t('improve.alreadyInstalledTitle')}</div>
        <div data-i18n="improve.alreadyInstalledDesc">${tHtml('improve.alreadyInstalledDesc')}</div>
      </div>
    `;
  }

  let reuseModalSequence = 0;
  let reuseOutcomesSequence = 0;

  function openConfigureReuseModal() {
    const registered = (state.registeredProjects || []);
    const scopedProject = state.currentProject;

    let selectedProj = '';
    if (scopedProject && registered.some(p => (p.path || p.id) === scopedProject)) {
      selectedProj = scopedProject;
    }

    const projectOptionsHtml = `
      <option value="" ${!selectedProj ? 'selected' : ''} data-i18n="reuse.selectProjectPlaceholder">${t('reuse.selectProjectPlaceholder')}</option>
      ${registered.map(p => {
        const pPath = p.path || p.id || '';
        const pDisplayName = p.title || p.name || (pPath ? pPath.split('/').filter(Boolean).pop() : t('common.unnamedProject'));
        const isSel = pPath === selectedProj;
        return `<option value="${safeEscapeHtml(pPath)}" ${isSel ? 'selected' : ''}>${safeEscapeHtml(pDisplayName)}</option>`;
      }).join('')}
    `;

    const bodyHtml = `
      <p style="font-size: 12px; color: var(--text-main); margin-bottom: 12px; line-height: 1.5;" data-i18n="reuse.modalNoticeDesc">
        ${t('reuse.modalNoticeDesc')}
      </p>
      <div class="form-group" style="margin-bottom: 12px;">
        <label class="form-label" for="reuse-project-select" style="font-size: 12px; font-weight: 600; margin-bottom: 4px; display: block;" data-i18n="reuse.targetProjectLabel">${t('reuse.targetProjectLabel')}</label>
        <select id="reuse-project-select" class="form-control" style="width: 100%; font-size: 12px; padding: 6px 8px;">
          ${projectOptionsHtml}
        </select>
      </div>
      <div id="reuse-dialog-error" role="alert" aria-live="polite"></div>
    `;

    const footerHtml = `
      <button class="btn btn-secondary" id="btn-cancel-reuse" data-i18n="common.cancel">${t('common.cancel')}</button>
      <button class="btn btn-primary" id="btn-preview-reuse" data-i18n="reuse.btnPreviewDiff" ${!selectedProj ? 'disabled' : ''}>${t('reuse.btnPreviewDiff')}</button>
    `;

    openModal({ key: 'reuse.modalTitle' }, bodyHtml, footerHtml);

    const sel = document.getElementById('reuse-project-select');
    const btnPreview = document.getElementById('btn-preview-reuse');
    const btnCancel = document.getElementById('btn-cancel-reuse');
    const errEl = document.getElementById('reuse-dialog-error');

    if (btnCancel) {
      btnCancel.addEventListener('click', closeModal);
    }

    if (sel && btnPreview) {
      sel.addEventListener('change', () => {
        const val = (sel.value || '').trim();
        btnPreview.disabled = !val;
        if (errEl) errEl.innerHTML = '';
      });
    }

    if (btnPreview && sel) {
      btnPreview.addEventListener('click', async () => {
        const chosenProject = (sel.value || '').trim();
        if (!chosenProject) return;

        const registeredList = state.registeredProjects || [];
        const matchedProj = registeredList.find(p => (p.path || p.id) === chosenProject);
        if (!matchedProj || !matchedProj.path) {
          if (errEl) {
            errEl.innerHTML = `<div class="alert-banner alert-danger" style="margin-top: 10px; font-size: 11px;" data-i18n="reuse.unregisteredProjectError">${t('reuse.unregisteredProjectError')}</div>`;
          }
          return;
        }
        const verifiedProject = matchedProj.path;

        btnPreview.disabled = true;
        sel.disabled = true;
        const originalText = btnPreview.textContent;
        setElementDescriptor(btnPreview, { key: 'reuse.previewLoading' });
        if (errEl) errEl.innerHTML = '';

        const thisSeq = ++reuseModalSequence;
        const thisModal = currentModalInstance;
        const thisPage = state.currentPage;
        const thisProject = state.currentProject;

        try {
          const suggestion = await callBridge('reuse.preview', { project: verifiedProject });

          const modal = document.getElementById('modal-container');
          const isModalOpen = modal && !modal.classList.contains('hidden');
          if (thisSeq !== reuseModalSequence || thisModal !== currentModalInstance || !isModalOpen || !document.contains(modal) || state.currentPage !== thisPage || state.currentProject !== thisProject) {
            return;
          }

          closeModal();
          if (suggestion && suggestion.id) {
            openImprovePreviewDrawer(suggestion.id);
          } else {
            showToast({ key: 'reuse.previewMissingIdToast' }, 'warning');
          }
        } catch (err) {
          const modal = document.getElementById('modal-container');
          const isModalOpen = modal && !modal.classList.contains('hidden');
          if (thisSeq !== reuseModalSequence || thisModal !== currentModalInstance || !isModalOpen || !document.contains(modal) || state.currentPage !== thisPage || state.currentProject !== thisProject) {
            return;
          }

          btnPreview.disabled = false;
          setElementDescriptor(btnPreview, { key: 'reuse.btnSimulatePreview' });
          sel.disabled = false;
          if (errEl) {
            errEl.innerHTML = `
              <div class="alert-banner alert-danger" style="margin-top: 10px; font-size: 11px;">
                ${t('reuse.previewFailedError', { error: safeEscapeHtml(err.message || String(err)) })}
              </div>
            `;
          }
        }
      });
    }
  }

  async function openReuseOutcomesDrawer(memoryId) {
    if (!memoryId) {
      showToast({ key: 'reuse.missingIdToast' }, 'warning');
      return;
    }

    const memories = (state.dashboard && state.dashboard.memories) || [];
    const mem = memories.find(m => m.id === memoryId);

    if (!mem) {
      showToast({ key: 'reuse.memNotFoundToast' }, 'warning');
      return;
    }

    const targetProject = mem.project;
    if (!targetProject || typeof targetProject !== 'string') {
      showToast({ key: 'reuse.missingProjectToast' }, 'warning');
      return;
    }

    const projObj = (state.registeredProjects || []).find(p => p && p.path === targetProject);
    if (!projObj || !projObj.path) {
      showToast({ key: 'reuse.projectNotConnectedToast' }, 'warning');
      return;
    }

    const projectFriendlyName = projObj.title || projObj.name || (targetProject ? targetProject.split('/').filter(Boolean).pop() : t('common.currentProject'));
    const memTitle = mem.title || t('reuse.defaultMemoryTitle');

    openDrawer({ key: 'reuse.drawerTitle' }, `${memTitle} · ${projectFriendlyName}`);

    const thisSeq = ++reuseOutcomesSequence;
    const thisDrawer = currentDrawerInstance;
    const thisPage = state.currentPage;
    const thisProject = state.currentProject;

    try {
      const outcomes = await callBridge('reuse.outcomes', { project: targetProject, id: memoryId });

      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== reuseOutcomesSequence || thisDrawer !== currentDrawerInstance || !isDrawerOpen || !document.contains(drawer) || state.currentPage !== thisPage || state.currentProject !== thisProject) {
        return;
      }

      if (!outcomes) {
        const e = new Error('reuse.noOutcomesData');
        e.i18nKey = 'reuse.noOutcomesData';
        throw e;
      }

      renderReuseOutcomesDrawerContent(outcomes, mem, targetProject, projectFriendlyName);
    } catch (err) {
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== reuseOutcomesSequence || thisDrawer !== currentDrawerInstance || !isDrawerOpen || !document.contains(drawer) || state.currentPage !== thisPage || state.currentProject !== thisProject) {
        return;
      }

      setDrawerTitle({ key: 'reuse.fetchFailedDrawerTitle' }, { key: 'reuse.fetchFailedDrawerSubtitle' });
      const drawerBody = document.getElementById('drawer-content');
      if (drawerBody) {
        if (err && err.i18nKey) {
          drawerBody.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="reuse.fetchFailedPrefix">${escapeHtml(t('reuse.fetchFailedPrefix'))}</span><span data-i18n="${err.i18nKey}">${escapeHtml(t(err.i18nKey))}</span>
            </div>
          `;
        } else {
          drawerBody.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="reuse.fetchFailedPrefix">${escapeHtml(t('reuse.fetchFailedPrefix'))}</span><span>${safeEscapeHtml(err.message || String(err))}</span>
            </div>
          `;
        }
      }
    }
  }

  function renderReuseOutcomesDrawerContent(outcomes, mem, targetProject, projectFriendlyName) {
    const drawerBody = document.getElementById('drawer-content');
    if (!drawerBody) return;

    const receipts = Array.isArray(outcomes.receipts) ? outcomes.receipts : [];
    const offeredSessions = outcomes.offeredSessions;
    const matchedSessions = outcomes.matchedSessions;
    const indexedSessionRecords = outcomes.indexedSessionRecords;
    const sessionIds = Array.isArray(outcomes.sessionIds) ? outcomes.sessionIds : [];
    const signals = Array.isArray(outcomes.observedVerificationSignals) ? outcomes.observedVerificationSignals : [];

    const verificationCorrectionCount = outcomes.verificationCorrectionCount;
    const agentAdoption = outcomes.agentAdoption;
    const analysisCoverage = outcomes.analysisCoverage;

    const limitations = Array.isArray(outcomes.limitations) ? outcomes.limitations : [];
    const method = outcomes.method || '';
    const knownSessions = (state.dashboard && state.dashboard.sessions) || [];

    const displayCorrectionCount = (verificationCorrectionCount !== null && isSafeNonNegativeInteger(verificationCorrectionCount))
      ? verificationCorrectionCount.toLocaleString()
      : t('common.notProvided');

    const displayReduction = t('common.notProvided');

    const displayAdoption = (agentAdoption === 'not_measured' || !agentAdoption)
      ? t('reuse.notMeasured')
      : safeEscapeHtml(agentAdoption);

    const displayCoverage = (analysisCoverage === 'not_established' || !analysisCoverage)
      ? t('reuse.notEstablished')
      : safeEscapeHtml(analysisCoverage);

    drawerBody.innerHTML = `
      <div class="card" style="margin-bottom: 10px; padding: 10px 12px;">
        <div class="card-header" style="margin-bottom: 6px;">
          <span class="card-title" style="font-size: 12px;">${safeEscapeHtml(mem.title || t('reuse.defaultMemoryTitle'))}</span>
          ${mem.state && typeof getMemoryStateBadge === 'function' ? getMemoryStateBadge(mem.state) : ''}
        </div>
        <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 6px;">
          <span data-i18n="reuse.projectLabel">${t('reuse.projectLabel')}</span><strong style="color: var(--text-main);">${safeEscapeHtml(projectFriendlyName)}</strong>
        </div>
        <details style="font-size: 10.5px; color: var(--text-muted);">
          <summary style="cursor: pointer; user-select: none;" data-i18n="reuse.techSummary">${t('reuse.techSummary')}</summary>
          <div class="font-mono" style="margin-top: 4px; display: grid; gap: 2px;">
            <div><span data-i18n="reuse.memoryIdLabel">${t('reuse.memoryIdLabel')}</span> <span style="user-select: all;">${safeEscapeHtml(mem.id)}</span></div>
            <div><span data-i18n="reuse.projectPathLabel">${t('reuse.projectPathLabel')}</span> <span style="user-select: all;">${safeEscapeHtml(targetProject)}</span></div>
          </div>
        </details>
      </div>

      <table class="data-table" style="width: 100%; font-size: 11px; margin-bottom: 10px; border: 1px solid var(--border-subtle); border-radius: var(--radius-sm); border-collapse: collapse;">
        <tbody>
          <tr style="border-bottom: 1px solid var(--border-subtle);">
            <td style="color: var(--text-secondary); padding: 5px 8px; width: 35%;" data-i18n="reuse.tableOfferedSessions">${t('reuse.tableOfferedSessions')}</td>
            <td class="font-mono" style="font-weight: 600; padding: 5px 8px;">${formatSafeCount(offeredSessions)}</td>
            <td style="color: var(--text-secondary); padding: 5px 8px; width: 35%;" data-i18n="reuse.tableMatchedSessions">${t('reuse.tableMatchedSessions')}</td>
            <td class="font-mono" style="font-weight: 600; padding: 5px 8px;">${formatSafeCount(matchedSessions)}</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--border-subtle);">
            <td style="color: var(--text-secondary); padding: 5px 8px;" data-i18n="reuse.tableIndexedRecords">${t('reuse.tableIndexedRecords')}</td>
            <td class="font-mono" style="font-weight: 600; padding: 5px 8px;">${formatSafeCount(indexedSessionRecords)}</td>
            <td style="color: var(--text-secondary); padding: 5px 8px;" data-i18n="reuse.tableReceiptsCount">${t('reuse.tableReceiptsCount')}</td>
            <td class="font-mono" style="font-weight: 600; padding: 5px 8px;">${receipts.length}</td>
          </tr>
          <tr style="border-bottom: 1px solid var(--border-subtle);">
            <td style="color: var(--text-secondary); padding: 5px 8px;" data-i18n="reuse.tableCoverage">${t('reuse.tableCoverage')}</td>
            <td style="padding: 5px 8px;"><span class="status-badge status-neutral">${displayCoverage}</span></td>
            <td style="color: var(--text-secondary); padding: 5px 8px;" data-i18n="reuse.tableAdoption">${t('reuse.tableAdoption')}</td>
            <td style="padding: 5px 8px;"><span class="status-badge status-neutral">${displayAdoption}</span></td>
          </tr>
          <tr>
            <td style="color: var(--text-secondary); padding: 5px 8px;" data-i18n="reuse.tableCorrectionCount">${t('reuse.tableCorrectionCount')}</td>
            <td style="color: var(--text-muted); padding: 5px 8px;">${displayCorrectionCount}</td>
            <td style="color: var(--text-secondary); padding: 5px 8px;" data-i18n="reuse.tableCorrectionRate">${t('reuse.tableCorrectionRate')}</td>
            <td style="color: var(--text-muted); padding: 5px 8px;">${displayReduction}</td>
          </tr>
        </tbody>
      </table>

      <div class="improve-methodology-note" role="note" style="margin-bottom: 12px;">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>
        <span data-i18n="reuse.methodologyNote">${t('reuse.methodologyNote')}</span>
      </div>

      <div style="margin-bottom: 16px;">
        <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;" data-i18n="reuse.receiptsTitle" data-i18n-params="${escapeHtml(JSON.stringify({ count: receipts.length }))}">${t('reuse.receiptsTitle', { count: receipts.length })}</h3>
        ${receipts.length === 0 ? `
          <div class="empty-state" style="padding: 16px 14px; margin-bottom: 12px;">
            <div class="empty-state-title" style="font-size: 12.5px;" data-i18n="reuse.emptyReceiptsTitle">${t('reuse.emptyReceiptsTitle')}</div>
            <div class="empty-state-desc" style="font-size: 11px; line-height: 1.6; text-align: left; margin-top: 8px; max-width: 480px; margin-left: auto; margin-right: auto;" data-i18n="reuse.emptyReceiptsDesc">
              ${t('reuse.emptyReceiptsDesc')}
            </div>
          </div>
        ` : `
          <div style="display: flex; flex-direction: column; gap: 8px;">
            ${receipts.map(r => {
              const matchedRecord = knownSessions.find(s =>
                s.project === targetProject &&
                String(s.provider || '').toLowerCase() === 'codex' &&
                Boolean(s.sourceSessionId && s.sourceSessionId === r.sourceSessionId) &&
                sessionIds.includes(s.id)
              );
              const isMapped = Boolean(matchedRecord);
              const displayTokens = (r.usedTokens !== null && r.usedTokens !== undefined && isSafeNonNegativeInteger(r.usedTokens))
                ? r.usedTokens.toLocaleString()
                : t('common.notProvided');

              return `
                <div class="card" style="margin-bottom: 0; padding: 10px 12px;">
                  <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; margin-bottom: 4px;">
                    <div style="display: flex; align-items: center; gap: 6px; font-size: 11px;">
                      <span class="status-badge status-sage" data-i18n="reuse.badgeContextProvided">${t('reuse.badgeContextProvided')}</span>
                      <span style="color: var(--text-secondary);">${formatSafeTime(r.servedAt)}</span>
                      <span class="badge-subtle font-mono">${safeEscapeHtml(r.event || 'SessionStart')}</span>
                    </div>
                    <div>
                      ${isMapped ? `
                        <button type="button" class="btn-open-source" data-session-id="${safeEscapeHtml(matchedRecord.id)}" title="${t('reuse.indexedSessionTitle', { id: safeEscapeHtml(matchedRecord.id) })}">
                          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg>
                          <span>${safeEscapeHtml(matchedRecord.title || t('reuse.indexedSessionFallback'))}</span>
                        </button>
                      ` : `
                        <span style="color: var(--text-secondary); font-size: 11px;" data-i18n="reuse.unmatchedProviderSession">${t('reuse.unmatchedProviderSession')}</span>
                      `}
                    </div>
                  </div>

                  <details style="margin-top: 6px; font-size: 10px; color: var(--text-muted);">
                    <summary style="cursor: pointer; user-select: none;" data-i18n="reuse.receiptTechSummary">${t('reuse.receiptTechSummary')}</summary>
                    <div class="font-mono" style="margin-top: 4px; display: grid; gap: 2px;">
                      <div><span data-i18n="reuse.receiptIdLabel">${t('reuse.receiptIdLabel')}</span> <span style="user-select: all;">${safeEscapeHtml(r.id || '-')}</span></div>
                      <div><span data-i18n="reuse.providerSessionIdLabel">${t('reuse.providerSessionIdLabel')}</span> <span style="user-select: all;">${safeEscapeHtml(r.sourceSessionId || '-')}</span></div>
                      <div><span data-i18n="reuse.contextHashLabel">${t('reuse.contextHashLabel')}</span> <span style="user-select: all;">${safeEscapeHtml(r.contextHash || '-')}</span></div>
                      <div><span data-i18n="reuse.deliveryChannelLabel">${t('reuse.deliveryChannelLabel')}</span> <span>${safeEscapeHtml(r.delivery || '-')}</span></div>
                      <div><span data-i18n="reuse.usedTokensLabel">${t('reuse.usedTokensLabel')}</span> <span>${displayTokens}</span></div>
                    </div>
                  </details>
                </div>
              `;
            }).join('')}
          </div>
        `}
      </div>

      <div style="margin-bottom: 16px;">
        <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 4px;" data-i18n="reuse.subsequentSignalsTitle" data-i18n-params="${escapeHtml(JSON.stringify({ count: signals.length }))}">${t('reuse.subsequentSignalsTitle', { count: signals.length })}</h3>
        <p style="font-size: 11px; color: var(--text-secondary); margin-bottom: 8px;" data-i18n="reuse.subsequentSignalsSubtitle">
          ${t('reuse.subsequentSignalsSubtitle')}
        </p>
        ${signals.length === 0 ? `
          <div style="font-size: 12px; color: var(--text-muted); padding: 8px 0;" data-i18n="reuse.noSignals">${t('reuse.noSignals')}</div>
        ` : `
          <div style="display: flex; flex-direction: column; gap: 6px;">
            ${signals.map(sig => {
              const quote = sig.quote || sig.summary || sig.content || t('reuse.defaultSignalContent');
              return `
                <div class="card" style="margin-bottom: 0; padding: 8px 12px;">
                  <div style="font-size: 12px; color: var(--text-main); font-style: italic; line-height: 1.45; margin-bottom: 4px;">
                    "${safeEscapeHtml(quote)}"
                  </div>
                  <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; font-size: 11px;">
                    <span class="badge-subtle font-mono">${safeEscapeHtml(sig.clusterKey || 'verification')}</span>
                    ${sig.sourceSession ? `
                      <button type="button" class="btn-open-source" data-session-id="${safeEscapeHtml(sig.sourceSession)}" ${sig.sourceMessage ? `data-message-id="${safeEscapeHtml(sig.sourceMessage)}"` : ''} title="${t('reuse.locateSignalSessionTooltip')}" data-i18n-title="reuse.locateSignalSessionTooltip">
                        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg>
                        <span data-i18n="reuse.locateSourceMsg">${t('reuse.locateSourceMsg')}</span>
                      </button>
                    ` : ''}
                  </div>
                  <details style="margin-top: 4px; font-size: 10px; color: var(--text-muted);">
                    <summary style="cursor: pointer; user-select: none;" data-i18n="reuse.signalTechSummary">${t('reuse.signalTechSummary')}</summary>
                    <div class="font-mono" style="margin-top: 2px;">
                      <div><span data-i18n="reuse.sessionIdLabel">${t('reuse.sessionIdLabel')}</span> ${safeEscapeHtml(sig.sourceSession || '-')}</div>
                      ${sig.sourceMessage ? `<div><span data-i18n="reuse.messageIdLabel">${t('reuse.messageIdLabel')}</span> ${safeEscapeHtml(sig.sourceMessage)}</div>` : ''}
                    </div>
                  </details>
                </div>
              `;
            }).join('')}
          </div>
        `}
      </div>

      ${(method || limitations.length > 0) ? `
        <details class="card" style="margin-top: 10px; padding: 8px 12px;">
          <summary style="font-size: 11px; font-weight: 600; cursor: pointer; color: var(--text-secondary); user-select: none;" data-i18n="reuse.methodologySummary">${t('reuse.methodologySummary')}</summary>
          ${method ? `<div style="font-size: 11px; color: var(--text-secondary); margin-top: 6px; line-height: 1.5;">${safeEscapeHtml(method)}</div>` : ''}
          ${limitations.length > 0 ? `
            <ul style="padding-left: 18px; font-size: 10.5px; color: var(--text-muted); margin-top: 6px; line-height: 1.5;">
              ${limitations.map(lim => `<li>${safeEscapeHtml(lim)}</li>`).join('')}
            </ul>
          ` : ''}
        </details>
      ` : ''}
    `;
  }

  // --- Complete Memory Management (Lifecycle tabs, Blume content-first cards, provenance) ---
  function renderMemorySection(target) {
    const memories = (state.dashboard && state.dashboard.memories) || [];
    const activeFilter = state.memoryFilter || 'all';

    const filterTabs = [
      { key: 'all', labelKey: 'memory.tabAll', label: t('memory.tabAll'), count: memories.length },
      { key: 'candidate', labelKey: 'memory.tabCandidate', label: t('memory.tabCandidate'), count: memories.filter(m => (m.state || 'candidate').toLowerCase() === 'candidate').length },
      { key: 'active', labelKey: 'memory.tabActive', label: t('memory.tabActive'), count: memories.filter(m => (m.state || '').toLowerCase() === 'active').length },
      { key: 'superseded', labelKey: 'memory.tabSuperseded', label: t('memory.tabSuperseded'), count: memories.filter(m => (m.state || '').toLowerCase() === 'superseded').length },
      { key: 'archived', labelKey: 'memory.tabArchived', label: t('memory.tabArchived'), count: memories.filter(m => (m.state || '').toLowerCase() === 'archived').length }
    ];

    const displayedMemories = memories.filter(m => {
      if (activeFilter === 'all') return true;
      const st = (m.state || 'candidate').toLowerCase();
      return st === activeFilter;
    });

    target.innerHTML = `
      <div class="memory-filter-bar">
        ${filterTabs.map(tab => `
          <button type="button" class="memory-filter-btn ${activeFilter === tab.key ? 'active' : ''}" data-filter="${tab.key}">
            <span data-i18n="${tab.labelKey}">${tab.label}</span>
            <span class="memory-filter-count">${tab.count}</span>
          </button>
        `).join('')}
        <div style="margin-left: auto; display: flex; gap: 8px;">
          <button id="btn-configure-reuse" class="btn btn-secondary btn-sm" data-i18n="memory.btnConfigReuse">${t('memory.btnConfigReuse')}</button>
          <button id="btn-recall-tester" class="btn btn-secondary btn-sm" data-i18n="memory.btnRecallTester">${t('memory.btnRecallTester')}</button>
          <button id="btn-new-memory" class="btn btn-primary btn-sm" data-i18n="memory.btnNewMemory">${t('memory.btnNewMemory')}</button>
        </div>
      </div>

      <div class="memory-card-list">
        ${memories.length === 0 ? `
          <div class="empty-state">
            <div class="empty-state-title" data-i18n="memory.emptyTitle">${t('memory.emptyTitle')}</div>
            <div class="empty-state-desc" data-i18n="memory.emptyDesc">${t('memory.emptyDesc')}</div>
            <button id="btn-empty-new-mem" class="btn btn-primary btn-sm" style="margin-top: 12px;" data-i18n="memory.btnNewMemory">${t('memory.btnNewMemory')}</button>
          </div>
        ` : (displayedMemories.length === 0 ? `
          <div class="empty-state" style="padding: 32px 16px;">
            <div class="empty-state-desc" data-i18n="memory.categoryEmptyDesc" data-i18n-params="${escapeHtml(JSON.stringify({ category: filterTabs.find(t => t.key === activeFilter)?.label || activeFilter }))}">${t('memory.categoryEmptyDesc', { category: filterTabs.find(t => t.key === activeFilter)?.label || activeFilter })}</div>
          </div>
        ` : displayedMemories.map(m => {
          const st = (m.state || 'candidate').toLowerCase();
          let provenanceHtml = '';
          if (m.sourceSession) {
            const knownSession = ((state.dashboard && state.dashboard.sessions) || []).find(s => s.id === m.sourceSession);
            const sessionLabel = (knownSession && knownSession.title) ? knownSession.title : t('memory.sourceSessionDefault');
            const tooltipTitle = m.sourceMessage
              ? t('memory.sourceSessionTooltip', { sessionId: m.sourceSession, messageId: m.sourceMessage })
              : t('memory.sourceSessionTooltipShort', { sessionId: m.sourceSession });
            provenanceHtml = `
              <span data-i18n="memory.sourcePrefix">${t('memory.sourcePrefix')}</span>
              <button type="button" class="btn-open-source" data-session-id="${escapeHtml(m.sourceSession)}" ${m.sourceMessage ? `data-message-id="${escapeHtml(m.sourceMessage)}"` : ''} title="${escapeHtml(tooltipTitle)}">
                <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg>
                <span>${escapeHtml(sessionLabel)}</span>
              </button>
            `;
          } else if (m.sourceFile) {
            provenanceHtml = `<span><span data-i18n="memory.sourceFilePrefix">${t('memory.sourceFilePrefix')}</span><span class="font-mono">${escapeHtml(m.sourceFile)}</span></span>`;
          } else if (m.sourceCommit) {
            provenanceHtml = `<span><span data-i18n="memory.sourceCommitPrefix">${t('memory.sourceCommitPrefix')}</span><span class="font-mono">${escapeHtml(m.sourceCommit.slice(0, 7))}</span></span>`;
          } else {
            provenanceHtml = `<span style="color: var(--text-muted);" data-i18n="memory.manualOrigin">${t('memory.manualOrigin')}</span>`;
          }

          return `
            <div class="memory-card" data-id="${escapeHtml(m.id)}">
              <div class="memory-card-header">
                <div class="memory-card-title-group">
                  <strong class="memory-card-title">${escapeHtml(m.title || t('memory.unnamedMemory'))}</strong>
                  ${getMemoryStateBadge(st)}
                  ${renderMemoryTypeBadge(m.type)}
                  ${renderMemoryScopeBadge(m.scope)}
                </div>
                <div class="memory-card-actions">
                  ${st === 'candidate' ? `<button class="btn btn-secondary btn-sm btn-mem-activate" data-id="${escapeHtml(m.id)}" data-i18n="memory.btnActivate">${t('memory.btnActivate')}</button>` : ''}
                  ${st === 'active' ? `<button class="btn btn-ghost btn-sm btn-mem-supersede" data-id="${escapeHtml(m.id)}" title="${t('memory.btnSupersedeTitle')}" data-i18n-title="memory.btnSupersedeTitle" data-i18n="memory.btnSupersede">${t('memory.btnSupersede')}</button>` : ''}
                  ${st !== 'archived' ? `<button class="btn btn-ghost btn-sm btn-mem-archive" data-id="${escapeHtml(m.id)}" data-i18n="memory.btnArchive">${t('memory.btnArchive')}</button>` : ''}
                  <button class="btn btn-ghost btn-sm btn-memory-outcomes" data-memory-id="${escapeHtml(m.id)}" data-i18n="memory.btnOutcomes">${t('memory.btnOutcomes')}</button>
                  <button class="btn btn-ghost btn-sm btn-mem-edit" data-id="${escapeHtml(m.id)}" data-i18n="memory.btnEdit">${t('memory.btnEdit')}</button>
                  <button class="btn btn-ghost btn-sm btn-mem-view" data-id="${escapeHtml(m.id)}" data-i18n="memory.btnViewDetails">${t('memory.btnViewDetails')}</button>
                </div>
              </div>

              <div class="memory-content">${escapeHtml(m.content || '')}</div>

              <div class="memory-provenance">
                ${provenanceHtml}
              </div>

              <details class="memory-meta-details">
                <summary data-i18n="memory.techMetaSummary">${t('memory.techMetaSummary')}</summary>
                <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 6px; font-size: 11px; margin-top: 8px; color: var(--text-secondary);">
                  <div><span class="text-secondary" data-i18n="memory.metaId">${t('memory.metaId')}</span> <span class="font-mono" style="user-select: all;">${escapeHtml(m.id || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaScope">${t('memory.metaScope')}</span> <span class="font-mono">${escapeHtml(m.scope || 'project')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaProject">${t('memory.metaProject')}</span> <span class="font-mono">${escapeHtml(m.project || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaBranch">${t('memory.metaBranch')}</span> <span class="font-mono">${escapeHtml(m.branch || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaWorktree">${t('memory.metaWorktree')}</span> <span class="font-mono">${escapeHtml(m.worktree || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaTask">${t('memory.metaTask')}</span> <span class="font-mono">${escapeHtml(m.task || '-')}</span></div>
                  ${(m.checksum || m.hash) ? `<div><span class="text-secondary" data-i18n="memory.metaChecksum">${t('memory.metaChecksum')}</span> <span class="font-mono">${escapeHtml(m.checksum || m.hash)}</span></div>` : ''}
                  <div><span class="text-secondary" data-i18n="memory.metaUpdatedAt">${t('memory.metaUpdatedAt')}</span> <span>${formatTime(m.updatedAt || m.createdAt)}</span></div>
                </div>
              </details>
            </div>
          `;
        }).join(''))}
      </div>
    `;

    target.querySelectorAll('.memory-filter-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        state.memoryFilter = btn.getAttribute('data-filter') || 'all';
        renderMemorySection(target);
      });
    });

    const btnNew = document.getElementById('btn-new-memory');
    if (btnNew) btnNew.addEventListener('click', () => openCreateOrEditMemoryModal());

    const btnEmptyNew = document.getElementById('btn-empty-new-mem');
    if (btnEmptyNew) btnEmptyNew.addEventListener('click', () => openCreateOrEditMemoryModal());

    const btnConfigReuse = document.getElementById('btn-configure-reuse');
    if (btnConfigReuse) btnConfigReuse.addEventListener('click', openConfigureReuseModal);

    const btnRecall = document.getElementById('btn-recall-tester');
    if (btnRecall) btnRecall.addEventListener('click', openRecallModal);

    target.querySelectorAll('.btn-mem-activate').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-id');
        try {
          await callBridge('memory.transition', { id, state: 'active' });
          showToast({ key: 'memory.activatedToast' });
          await refreshDashboard(true, true);
        } catch (e) {
          showToast({ key: 'memory.activateFailedToast', params: { error: e.message } }, 'error');
        }
      });
    });

    target.querySelectorAll('.btn-mem-archive').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-id');
        try {
          await callBridge('memory.transition', { id, state: 'archived' });
          showToast({ key: 'memory.archivedToast' });
          await refreshDashboard(true, true);
        } catch (e) {
          showToast({ key: 'memory.archiveFailedToast', params: { error: e.message } }, 'error');
        }
      });
    });

    target.querySelectorAll('.btn-mem-supersede').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        openSupersedeMemoryModal(id);
      });
    });

    target.querySelectorAll('.btn-mem-edit').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        const m = memories.find(item => item.id === id);
        if (m) openCreateOrEditMemoryModal(m);
      });
    });

    target.querySelectorAll('.btn-memory-outcomes').forEach(btn => {
      btn.addEventListener('click', () => {
        const memId = btn.getAttribute('data-memory-id');
        openReuseOutcomesDrawer(memId);
      });
    });

    target.querySelectorAll('.btn-mem-view').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        const m = memories.find(item => item.id === id);
        if (m) {
          openDrawer(m.title || t('memory.unnamedMemory'), m.id);
          const drawerBody = document.getElementById('drawer-content');
          if (drawerBody) {
            drawerBody.innerHTML = `
              <div class="card">
                <div class="card-header">
                  <span class="card-title" data-i18n="memory.drawerMetaTitle">${t('memory.drawerMetaTitle')}</span>
                  ${getMemoryStateBadge(m.state)}
                </div>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 6px; font-size: 11px;">
                  <div><span class="text-secondary" data-i18n="memory.metaType">${t('memory.metaType')}</span> ${renderMemoryTypeInline(m.type)} (${escapeHtml(m.type || '-')})</div>
                  <div><span class="text-secondary" data-i18n="memory.metaScope">${t('memory.metaScope')}</span> ${renderMemoryScopeInline(m.scope)} (${escapeHtml(m.scope || '-')})</div>
                  <div><span class="text-secondary" data-i18n="memory.metaProject">${t('memory.metaProject')}</span> ${escapeHtml(m.project || '-')}</div>
                  <div><span class="text-secondary" data-i18n="memory.metaBranch">${t('memory.metaBranch')}</span> <span class="font-mono">${escapeHtml(m.branch || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaWorktree">${t('memory.metaWorktree')}</span> <span class="font-mono">${escapeHtml(m.worktree || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaTask">${t('memory.metaTask')}</span> ${escapeHtml(m.task || '-')}</div>
                  <div><span class="text-secondary" data-i18n="memory.metaSourceFile">${t('memory.metaSourceFile')}</span> <span class="font-mono">${escapeHtml(m.sourceFile || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaSourceCommit">${t('memory.metaSourceCommit')}</span> <span class="font-mono">${escapeHtml(m.sourceCommit || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaSourceSession">${t('memory.metaSourceSession')}</span> <span class="font-mono">${escapeHtml(m.sourceSession || '-')}</span></div>
                  <div><span class="text-secondary" data-i18n="memory.metaSourceMessage">${t('memory.metaSourceMessage')}</span> <span class="font-mono">${escapeHtml(m.sourceMessage || '-')}</span></div>
                </div>
                <div style="margin-top: 10px; padding-top: 8px; border-top: 1px dashed var(--border-color); display: flex; gap: 8px; flex-wrap: wrap;">
                  <button type="button" class="btn btn-secondary btn-sm btn-drawer-memory-outcomes" data-memory-id="${escapeHtml(m.id)}">
                    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
                    <span data-i18n="memory.btnViewReuseOutcomes">${t('memory.btnViewReuseOutcomes')}</span>
                  </button>
                  ${m.sourceSession ? `
                    <button type="button" class="btn-open-source" data-session-id="${escapeHtml(m.sourceSession)}" ${m.sourceMessage ? `data-message-id="${escapeHtml(m.sourceMessage)}"` : ''}>
                      <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg>
                      <span data-i18n="memory.btnLocateSourceMsg">${t('memory.btnLocateSourceMsg')}</span>
                    </button>
                  ` : ''}
                </div>
              </div>
              <div>
                <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;" data-i18n="memory.drawerContentTitle">${t('memory.drawerContentTitle')}</h3>
                <div class="code-view">${escapeHtml(m.content || '')}</div>
              </div>
            `;
            const outcomesBtn = drawerBody.querySelector('.btn-drawer-memory-outcomes');
            if (outcomesBtn) {
              outcomesBtn.addEventListener('click', () => {
                openReuseOutcomesDrawer(m.id);
              });
            }
          }
        }
      });
    });
  }

  function getMemoryStateBadge(stateStr) {
    const s = (stateStr || '').toLowerCase();
    switch (s) {
      case 'active':
        return `<span class="status-badge status-sage" data-i18n="memory.stateActive">${t('memory.stateActive')}</span>`;
      case 'candidate':
        return `<span class="status-badge status-amber" data-i18n="memory.stateCandidate">${t('memory.stateCandidate')}</span>`;
      case 'superseded':
        return `<span class="status-badge status-neutral" data-i18n="memory.stateSuperseded">${t('memory.stateSuperseded')}</span>`;
      case 'archived':
        return `<span class="status-badge status-neutral" data-i18n="memory.stateArchived">${t('memory.stateArchived')}</span>`;
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(stateStr || t('memory.stateUnknown'))}</span>`;
    }
  }

  function openCreateOrEditMemoryModal(initial = {}) {
    const isEdit = !!initial.id;
    const validTypes = [
      'decision', 'constraint', 'preference', 'failure', 'fact',
      'workflow knowledge', 'observation', 'hypothesis', 'checkpoint'
    ];
    const validScopes = [
      'global', 'project', 'repository', 'branch', 'worktree', 'task', 'session'
    ];

    const modalBody = `
      <div class="form-group">
        <label class="form-label" data-i18n="memory.formTitle">${t('memory.formTitle')}</label>
        <input type="text" id="mem-title" class="form-input" value="${escapeHtml(initial.title || '')}" placeholder="${t('memory.formTitlePlaceholder')}" data-i18n-placeholder="memory.formTitlePlaceholder">
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="memory.formContent">${t('memory.formContent')}</label>
        <textarea id="mem-content" class="form-textarea" placeholder="${t('memory.formContentPlaceholder')}" data-i18n-placeholder="memory.formContentPlaceholder">${escapeHtml(initial.content || '')}</textarea>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formType">${t('memory.formType')}</label>
          <select id="mem-type" class="form-select">
            ${validTypes.map(typeVal => `<option value="${typeVal}" ${((initial.type || 'fact').toLowerCase() === typeVal) ? 'selected' : ''}>${typeVal}</option>`).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formScope">${t('memory.formScope')}</label>
          <select id="mem-scope" class="form-select">
            ${validScopes.map(scopeVal => `<option value="${scopeVal}" ${((initial.scope || 'project').toLowerCase() === scopeVal) ? 'selected' : ''}>${scopeVal}</option>`).join('')}
          </select>
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formProject">${t('memory.formProject')}</label>
          <select id="mem-project" class="form-select">
            <option value="" data-i18n="memory.formProjectGlobal">${t('memory.formProjectGlobal')}</option>
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}" ${(initial.project === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formState">${t('memory.formState')}</label>
          <select id="mem-state" class="form-select" ${isEdit ? 'disabled' : ''}>
            <option value="candidate" ${(initial.state || 'candidate').toLowerCase() === 'candidate' ? 'selected' : ''} data-i18n="memory.stateCandidate">${t('memory.stateCandidate')}</option>
            <option value="active" ${(initial.state || '').toLowerCase() === 'active' ? 'selected' : ''} data-i18n="memory.stateActive">${t('memory.stateActive')}</option>
            <option value="superseded" ${(initial.state || '').toLowerCase() === 'superseded' ? 'selected' : ''} data-i18n="memory.stateSuperseded">${t('memory.stateSuperseded')}</option>
            <option value="archived" ${(initial.state || '').toLowerCase() === 'archived' ? 'selected' : ''} data-i18n="memory.stateArchived">${t('memory.stateArchived')}</option>
          </select>
          ${isEdit ? `<div style="font-size: 10px; color: var(--text-secondary); margin-top: 2px;" data-i18n="memory.formStateEditNotice">${t('memory.formStateEditNotice')}</div>` : ''}
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formBranch">${t('memory.formBranch')}</label>
          <input type="text" id="mem-branch" class="form-input" value="${escapeHtml(initial.branch || '')}" placeholder="${t('memory.formBranchPlaceholder')}" data-i18n-placeholder="memory.formBranchPlaceholder">
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formWorktree">${t('memory.formWorktree')}</label>
          <input type="text" id="mem-worktree" class="form-input" value="${escapeHtml(initial.worktree || '')}" placeholder="${t('memory.formWorktreePlaceholder')}" data-i18n-placeholder="memory.formWorktreePlaceholder">
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formTask">${t('memory.formTask')}</label>
          <input type="text" id="mem-task" class="form-input" value="${escapeHtml(initial.task || '')}" placeholder="${t('memory.formTaskPlaceholder')}" data-i18n-placeholder="memory.formTaskPlaceholder">
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formSrcSession">${t('memory.formSrcSession')}</label>
          <input type="text" id="mem-src-session" class="form-input" value="${escapeHtml(initial.sourceSession || '')}" placeholder="${t('memory.formSrcSessionPlaceholder')}" data-i18n-placeholder="memory.formSrcSessionPlaceholder">
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formSrcMsg">${t('memory.formSrcMsg')}</label>
          <input type="text" id="mem-src-msg" class="form-input" value="${escapeHtml(initial.sourceMessage || '')}" placeholder="${t('memory.formSrcMsgPlaceholder')}" data-i18n-placeholder="memory.formSrcMsgPlaceholder">
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="memory.formSrcCommit">${t('memory.formSrcCommit')}</label>
          <input type="text" id="mem-src-commit" class="form-input" value="${escapeHtml(initial.sourceCommit || '')}" placeholder="${t('memory.formSrcCommitPlaceholder')}" data-i18n-placeholder="memory.formSrcCommitPlaceholder">
        </div>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="memory.formSrcFile">${t('memory.formSrcFile')}</label>
        <input type="text" id="mem-src-file" class="form-input" value="${escapeHtml(initial.sourceFile || '')}" placeholder="${t('memory.formSrcFilePlaceholder')}" data-i18n-placeholder="memory.formSrcFilePlaceholder">
      </div>
    `;

    openModal({ key: isEdit ? 'memory.editModalTitle' : 'memory.newModalTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-mem" data-i18n="common.cancel">${t('common.cancel')}</button>
      <button class="btn btn-primary" id="btn-save-mem" data-i18n="memory.btnSaveMemory">${t('memory.btnSaveMemory')}</button>
    `);

    document.getElementById('btn-cancel-mem').addEventListener('click', closeModal);
    document.getElementById('btn-save-mem').addEventListener('click', async () => {
      const title = document.getElementById('mem-title').value.trim();
      const content = document.getElementById('mem-content').value.trim();
      const type = document.getElementById('mem-type').value.toLowerCase();
      const scope = document.getElementById('mem-scope').value.toLowerCase();
      const project = document.getElementById('mem-project').value;
      const normalizedInitialState = (initial.state || 'candidate').toLowerCase();
      const memState = isEdit ? normalizedInitialState : document.getElementById('mem-state').value.toLowerCase();
      const branch = document.getElementById('mem-branch').value.trim();
      const worktree = document.getElementById('mem-worktree').value.trim();
      const task = document.getElementById('mem-task').value.trim();
      const sourceSession = document.getElementById('mem-src-session').value.trim();
      const sourceMessage = document.getElementById('mem-src-msg').value.trim();
      const sourceFile = document.getElementById('mem-src-file').value.trim();
      const sourceCommit = document.getElementById('mem-src-commit').value.trim();

      if (!title || !content) {
        showToast({ key: 'memory.validationTitleAndContentRequired' }, 'error');
        return;
      }
      if (scope !== 'global' && !project) {
        showToast({ key: 'memory.validationProjectRequired' }, 'error');
        return;
      }
      if (scope === 'branch' && !branch) {
        showToast({ key: 'memory.validationBranchRequired' }, 'error');
        return;
      }
      if (scope === 'worktree' && !worktree) {
        showToast({ key: 'memory.validationWorktreeRequired' }, 'error');
        return;
      }
      if (scope === 'task' && !task) {
        showToast({ key: 'memory.validationTaskRequired' }, 'error');
        return;
      }
      if (scope === 'session' && !sourceSession) {
        showToast({ key: 'memory.validationSessionRequired' }, 'error');
        return;
      }

      try {
        await callBridge('memory.save', {
          id: isEdit ? initial.id : undefined,
          title,
          content,
          type,
          scope,
          project: project || undefined,
          state: memState,
          branch: branch || undefined,
          worktree: worktree || undefined,
          task: task || undefined,
          sourceFile: sourceFile || undefined,
          sourceCommit: sourceCommit || undefined,
          sourceSession: sourceSession || undefined,
          sourceMessage: sourceMessage || undefined
        });
        showToast({ key: 'memory.savedToast' });
        closeModal();
        await refreshDashboard(true, true);
      } catch (err) {
        showToast({ key: 'memory.saveFailedToast', params: { error: err.message } }, 'error');
      }
    });
  }

  function openSupersedeMemoryModal(memoryId) {
    const memories = (state.dashboard && state.dashboard.memories) || [];
    const oldMem = memories.find(m => m.id === memoryId);
    const oldTitle = oldMem ? oldMem.title : memoryId;

    // Filter candidate or active memories from the same project
    const eligibleReplacements = memories.filter(m => {
      if (m.id === memoryId) return false;
      if (oldMem && oldMem.project && m.project !== oldMem.project) return false;
      const st = (m.state || '').toLowerCase();
      return st === 'candidate' || st === 'active';
    });

    const modalBody = `
      <p style="font-size: 12px; color: var(--text-secondary); margin-bottom: 12px; line-height: 1.6;" data-i18n="memory.supersedeNotice" data-i18n-params="${escapeHtml(JSON.stringify({ title: oldTitle }))}">
        ${t('memory.supersedeNotice', { title: escapeHtml(oldTitle) })}
      </p>
      ${eligibleReplacements.length === 0 ? `
        <div class="alert-banner alert-warning" style="margin-bottom: 12px; line-height: 1.6;" data-i18n="memory.noReplacementsNotice">
          ${t('memory.noReplacementsNotice')}
        </div>
      ` : `
        <div class="form-group">
          <label class="form-label" data-i18n="memory.selectReplacementLabel">${t('memory.selectReplacementLabel')}</label>
          <select id="mem-supersede-target" class="form-select">
            <option value="" data-i18n="memory.selectReplacementPlaceholder">${t('memory.selectReplacementPlaceholder')}</option>
            ${eligibleReplacements.map(m => `
              <option value="${escapeHtml(m.id)}">${escapeHtml(m.title)} (${escapeHtml(m.id.substring(0, 8))}) [${escapeHtml(m.state || 'active')}]</option>
            `).join('')}
          </select>
        </div>
      `}
    `;

    openModal({ key: 'memory.supersedeModalTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-supersede" data-i18n="common.cancel">${t('common.cancel')}</button>
      ${eligibleReplacements.length > 0 ? `<button class="btn btn-primary" id="btn-confirm-supersede" data-i18n="memory.btnConfirmSupersede">${t('memory.btnConfirmSupersede')}</button>` : ''}
    `);

    document.getElementById('btn-cancel-supersede').addEventListener('click', closeModal);
    const confirmBtn = document.getElementById('btn-confirm-supersede');
    if (confirmBtn) {
      confirmBtn.addEventListener('click', async () => {
        const replacementId = document.getElementById('mem-supersede-target').value;
        if (!replacementId) {
          showToast({ key: 'memory.validationSelectReplacement' }, 'error');
          return;
        }
        try {
          // Atomically activate replacement B and mark A as superseded
          await callBridge('memory.transition', {
            id: replacementId,
            state: 'active',
            supersedes: memoryId
          });
          showToast({ key: 'memory.supersededToast', params: { title: oldTitle } });
          closeModal();
          await refreshDashboard(true, true);
        } catch (err) {
          showToast({ key: 'memory.supersedeFailedToast', params: { error: err.message } }, 'error');
        }
      });
    }
  }

  function openRecallModal() {
    const modalBody = `
      <div class="form-group">
        <label class="form-label" data-i18n="memory.recallQueryLabel">${t('memory.recallQueryLabel')}</label>
        <input type="text" id="recall-query" class="form-input" placeholder="${t('memory.recallQueryPlaceholder')}" data-i18n-placeholder="memory.recallQueryPlaceholder">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label" data-i18n="memory.recallProjectLabel">${t('memory.recallProjectLabel')}</label>
          <select id="recall-project" class="form-select">
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}">${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="memory.recallBudgetLabel">${t('memory.recallBudgetLabel')}</label>
          <select id="recall-budget" class="form-select">
            <option value="500" data-i18n="memory.recallBudget500">${t('memory.recallBudget500')}</option>
            <option value="1000" selected data-i18n="memory.recallBudget1000">${t('memory.recallBudget1000')}</option>
            <option value="2000" data-i18n="memory.recallBudget2000">${t('memory.recallBudget2000')}</option>
            <option value="4000" data-i18n="memory.recallBudget4000">${t('memory.recallBudget4000')}</option>
          </select>
        </div>
      </div>
      <details style="margin-top: 8px; margin-bottom: 8px; font-size: 12px; color: var(--text-secondary);">
        <summary style="cursor: pointer; user-select: none; font-weight: 500;" data-i18n="memory.recallAdvancedSummary">${t('memory.recallAdvancedSummary')}</summary>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;" data-i18n="memory.recallBranchLabel">${t('memory.recallBranchLabel')}</label>
            <input type="text" id="recall-branch" class="form-input" style="font-size: 12px;" placeholder="${t('memory.recallBranchPlaceholder')}" data-i18n-placeholder="memory.recallBranchPlaceholder">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;" data-i18n="memory.recallWorktreeLabel">${t('memory.recallWorktreeLabel')}</label>
            <input type="text" id="recall-worktree" class="form-input" style="font-size: 12px;" placeholder="${t('memory.recallWorktreePlaceholder')}" data-i18n-placeholder="memory.recallWorktreePlaceholder">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;" data-i18n="memory.recallTaskLabel">${t('memory.recallTaskLabel')}</label>
            <input type="text" id="recall-task" class="form-input" style="font-size: 12px;" placeholder="${t('memory.recallTaskPlaceholder')}" data-i18n-placeholder="memory.recallTaskPlaceholder">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;" data-i18n="memory.recallSessionIdLabel">${t('memory.recallSessionIdLabel')}</label>
            <input type="text" id="recall-session-id" class="form-input" style="font-size: 12px;" placeholder="${t('memory.recallSessionIdPlaceholder')}" data-i18n-placeholder="memory.recallSessionIdPlaceholder">
          </div>
        </div>
      </details>
      <div id="recall-results-area" style="margin-top: 10px; max-height: 200px; overflow-y: auto;"></div>
    `;

    openModal({ key: 'memory.recallModalTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-close-recall" data-i18n="common.close">${t('common.close')}</button>
      <button class="btn btn-primary" id="btn-do-recall" data-i18n="memory.btnDoRecall">${t('memory.btnDoRecall')}</button>
    `);

    document.getElementById('btn-close-recall').addEventListener('click', closeModal);
    document.getElementById('btn-do-recall').addEventListener('click', async () => {
      const query = document.getElementById('recall-query').value.trim();
      const project = document.getElementById('recall-project').value;
      const budget = parseInt(document.getElementById('recall-budget').value, 10);
      const resultsArea = document.getElementById('recall-results-area');

      if (!query) {
        showToast({ key: 'memory.recallQueryRequired' }, 'error');
        return;
      }

      const branchVal = (document.getElementById('recall-branch')?.value || '').trim();
      const worktreeVal = (document.getElementById('recall-worktree')?.value || '').trim();
      const taskVal = (document.getElementById('recall-task')?.value || '').trim();
      const sessionIdVal = (document.getElementById('recall-session-id')?.value || '').trim();

      const recallPayload = {
        query,
        project,
        budget
      };
      if (branchVal) recallPayload.branch = branchVal;
      if (worktreeVal) recallPayload.worktree = worktreeVal;
      if (taskVal) recallPayload.task = taskVal;
      if (sessionIdVal) recallPayload.sessionId = sessionIdVal;

      resultsArea.innerHTML = `<div class="text-secondary" style="font-size: 11px;" data-i18n="memory.recalling">${t('memory.recalling')}</div>`;

      try {
        const res = await callBridge('recall', recallPayload);
        const items = (res && res.items) || [];
        const used = (res && res.usedTokens) || 0;

        resultsArea.innerHTML = `
          <div style="margin-bottom: 6px; font-size: 11px; display: flex; justify-content: space-between;">
            <span data-i18n="memory.recallMatchedCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: items.length }))}">${t('memory.recallMatchedCount', { count: items.length })}</span>
            <span class="font-mono" data-i18n="memory.recallTokensUsed" data-i18n-params="${escapeHtml(JSON.stringify({ used, budget }))}">${t('memory.recallTokensUsed', { used, budget })}</span>
          </div>
          <div style="display: flex; flex-direction: column; gap: 6px;">
            ${items.length === 0 ? `<div style="font-size: 11px; color: var(--text-muted);" data-i18n="memory.recallEmpty">${t('memory.recallEmpty')}</div>` : ''}
            ${items.map(it => `
              <div class="card" style="padding: 6px 10px; margin-bottom: 0;">
                <div style="font-weight: 600; font-size: 11px;">${escapeHtml(it.title)}</div>
                <div style="font-size: 11px; color: var(--text-secondary);">${escapeHtml(it.content)}</div>
              </div>
            `).join('')}
          </div>
        `;
      } catch (err) {
        resultsArea.innerHTML = `<div class="alert-banner alert-danger">${escapeHtml(err.message)}</div>`;
      }
    });
  }

  // --- Library Section (supports text, path, url) ---
  function renderLibrarySection(target) {
    const library = (state.dashboard && state.dashboard.library) || [];

    target.innerHTML = `
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
        <span class="text-secondary" style="font-size: 12px;" data-i18n="setupL.library.headerDesc" data-i18n-params="${escapeHtml(JSON.stringify({ count: library.length }))}">${escapeHtml(t('setupL.library.headerDesc', { count: library.length }))}</span>
        <button id="btn-add-library" class="btn btn-primary btn-sm" data-i18n="setupL.library.btnAdd">${escapeHtml(t('setupL.library.btnAdd'))}</button>
      </div>

      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th data-i18n="setupL.library.tableTitle">${escapeHtml(t('setupL.library.tableTitle'))}</th>
              <th data-i18n="setupL.library.tableProject">${escapeHtml(t('setupL.library.tableProject'))}</th>
              <th data-i18n="setupL.library.tablePrivacy">${escapeHtml(t('setupL.library.tablePrivacy'))}</th>
              <th data-i18n="setupL.library.tableSource">${escapeHtml(t('setupL.library.tableSource'))}</th>
              <th style="text-align: right; width: 100px;" data-i18n="setupL.table.actions">${escapeHtml(t('setupL.table.actions'))}</th>
            </tr>
          </thead>
          <tbody>
            ${library.length === 0 ? `<tr><td colspan="5" style="text-align: center; color: var(--text-muted); padding: 24px;" data-i18n="setupL.library.emptyText">${escapeHtml(t('setupL.library.emptyText'))}</td></tr>` : ''}
            ${library.map(lib => `
              <tr>
                <td><strong>${escapeHtml(lib.title)}</strong></td>
                <td><span class="code-badge">${lib.project ? escapeHtml(lib.project.split('/').pop()) : tHtml('setupL.scope.global')}</span></td>
                <td>
                  ${lib.private ? `<span class="status-badge status-amber" data-i18n="setupL.library.badgePrivate">${escapeHtml(t('setupL.library.badgePrivate'))}</span>` : `<span class="status-badge status-neutral" data-i18n="setupL.library.badgePublic">${escapeHtml(t('setupL.library.badgePublic'))}</span>`}
                </td>
                <td style="font-size: 11px; font-family: var(--font-mono); color: var(--text-muted);">
                  ${escapeHtml(lib.url || lib.path || (lib.content ? lib.content.substring(0, 40) + '...' : '-'))}
                </td>
                <td style="text-align: right;">
                  <button class="btn btn-secondary btn-sm btn-view-library" data-id="${escapeHtml(lib.id)}" data-i18n="setupL.common.view">${escapeHtml(t('setupL.common.view'))}</button>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      </div>
    `;

    document.getElementById('btn-add-library').addEventListener('click', openAddLibraryModal);

    target.querySelectorAll('.btn-view-library').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        const lib = library.find(item => item.id === id);
        if (lib) {
          openDrawer(lib.title || { key: 'setupL.library.drawerTitle' }, lib.id);
          document.getElementById('drawer-content').innerHTML = `
            <div class="card">
              <div class="card-header">
                <span class="card-title" data-i18n="setupL.drawer.basicInfo">${escapeHtml(t('setupL.drawer.basicInfo'))}</span>
                ${lib.private ? `<span class="status-badge status-amber" data-i18n="setupL.library.badgePrivateShort">${escapeHtml(t('setupL.library.badgePrivateShort'))}</span>` : `<span class="status-badge status-neutral" data-i18n="setupL.library.badgePublicShort">${escapeHtml(t('setupL.library.badgePublicShort'))}</span>`}
              </div>
              <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
                <div><span class="text-secondary" data-i18n="setupL.guidelines.projectLabel">${escapeHtml(t('setupL.guidelines.projectLabel'))}</span> ${lib.project ? escapeHtml(lib.project) : tHtml('setupL.scope.global')}</div>
                <div><span class="text-secondary" data-i18n="setupL.library.createdAtLabel">${escapeHtml(t('setupL.library.createdAtLabel'))}</span> ${formatTime(lib.createdAt)}</div>
              </div>
              ${lib.path ? `<div style="margin-top: 6px; font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);"><span data-i18n="setupL.library.filePathLabel">${escapeHtml(t('setupL.library.filePathLabel'))}</span>: ${escapeHtml(lib.path)}</div>` : ''}
              ${lib.url ? `<div style="margin-top: 6px; font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);"><span data-i18n="setupL.library.urlLabel">${escapeHtml(t('setupL.library.urlLabel'))}</span>: ${escapeHtml(lib.url)}</div>` : ''}
            </div>
            <div>
              <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;" data-i18n="setupL.library.contentTitle">${escapeHtml(t('setupL.library.contentTitle'))}</h3>
              <div class="code-view">${lib.content ? escapeHtml(lib.content) : tHtml('setupL.library.externalRef')}</div>
            </div>
          `;
        }
      });
    });
  }

  function openAddLibraryModal() {
    const modalBody = `
      <div class="form-group">
        <label class="form-label" data-i18n="setupL.library.modalSourceTypeLabel">${escapeHtml(t('setupL.library.modalSourceTypeLabel'))}</label>
        <select id="lib-source-type" class="form-select">
          <option value="content" data-i18n="setupL.library.sourceTypeContent">${escapeHtml(t('setupL.library.sourceTypeContent'))}</option>
          <option value="path" data-i18n="setupL.library.sourceTypePath">${escapeHtml(t('setupL.library.sourceTypePath'))}</option>
          <option value="url" data-i18n="setupL.library.sourceTypeUrl">${escapeHtml(t('setupL.library.sourceTypeUrl'))}</option>
        </select>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="setupL.library.modalDocTitleLabel">${escapeHtml(t('setupL.library.modalDocTitleLabel'))}</label>
        <input type="text" id="lib-title" class="form-input" placeholder="${escapeHtml(t('setupL.library.modalDocTitlePlaceholder'))}" data-i18n-placeholder="setupL.library.modalDocTitlePlaceholder">
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="setupL.library.modalProjectLabel">${escapeHtml(t('setupL.library.modalProjectLabel'))}</label>
        <select id="lib-project" class="form-select">
          <option value="" data-i18n="setupL.library.modalProjectGlobal">${escapeHtml(t('setupL.library.modalProjectGlobal'))}</option>
          ${state.registeredProjects.map(p => `
            <option value="${escapeHtml(p.path || p.id)}">${escapeHtml(p.title || p.path)}</option>
          `).join('')}
        </select>
      </div>
      <div class="form-group" id="lib-group-content">
        <label class="form-label" data-i18n="setupL.library.modalTextContentLabel">${escapeHtml(t('setupL.library.modalTextContentLabel'))}</label>
        <textarea id="lib-content" class="form-textarea" placeholder="${escapeHtml(t('setupL.library.modalTextContentPlaceholder'))}" data-i18n-placeholder="setupL.library.modalTextContentPlaceholder"></textarea>
      </div>
      <div class="form-group hidden" id="lib-group-path">
        <label class="form-label" data-i18n="setupL.library.modalPathLabel">${escapeHtml(t('setupL.library.modalPathLabel'))}</label>
        <input type="text" id="lib-path" class="form-input font-mono" placeholder="/path/to/document.md">
      </div>
      <div class="form-group hidden" id="lib-group-url">
        <label class="form-label" data-i18n="setupL.library.modalUrlLabel">${escapeHtml(t('setupL.library.modalUrlLabel'))}</label>
        <input type="url" id="lib-url" class="form-input font-mono" placeholder="https://example.com/docs">
      </div>
      <div class="form-group">
        <label class="form-checkbox-label">
          <input type="checkbox" id="lib-private" checked>
          <span data-i18n="setupL.library.modalPrivateCheckbox">${escapeHtml(t('setupL.library.modalPrivateCheckbox'))}</span>
        </label>
      </div>
    `;

    openModal({ key: 'setupL.library.modalAddTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-lib" data-i18n="setupL.common.cancel">${escapeHtml(t('setupL.common.cancel'))}</button>
      <button class="btn btn-primary" id="btn-save-lib" data-i18n="setupL.library.btnSave">${escapeHtml(t('setupL.library.btnSave'))}</button>
    `);

    const selType = document.getElementById('lib-source-type');
    const pathInput = document.getElementById('lib-path');
    const privCb = document.getElementById('lib-private');

    const forcedPrivateSubstrings = ['.env', 'credentials', 'secret', 'id_rsa', '.key', '.pem'];
    const updateForcedPrivatePolicy = () => {
      if (selType.value === 'path') {
        const val = (pathInput.value || '').toLowerCase();
        const isForced = forcedPrivateSubstrings.some(sub => val.includes(sub));
        if (isForced) {
          privCb.checked = true;
          privCb.disabled = true;
        } else {
          privCb.disabled = false;
        }
      } else {
        privCb.disabled = false;
      }
    };

    pathInput.addEventListener('input', updateForcedPrivatePolicy);
    selType.addEventListener('change', () => {
      const v = selType.value;
      document.getElementById('lib-group-content').classList.toggle('hidden', v !== 'content');
      document.getElementById('lib-group-path').classList.toggle('hidden', v !== 'path');
      document.getElementById('lib-group-url').classList.toggle('hidden', v !== 'url');
      updateForcedPrivatePolicy();
    });

    document.getElementById('btn-cancel-lib').addEventListener('click', closeModal);
    document.getElementById('btn-save-lib').addEventListener('click', async () => {
      const title = document.getElementById('lib-title').value.trim();
      const project = document.getElementById('lib-project').value;
      const sourceType = selType.value;
      const isPrivate = privCb.checked || privCb.disabled;

      if (!title) {
        showToast({ key: 'setupL.library.toastTitleRequired' }, 'error');
        return;
      }

      let payload = {
        title,
        project: project || undefined,
        private: isPrivate
      };

      if (sourceType === 'content') {
        payload.content = document.getElementById('lib-content').value.trim();
      } else if (sourceType === 'path') {
        payload.path = document.getElementById('lib-path').value.trim();
      } else if (sourceType === 'url') {
        payload.url = document.getElementById('lib-url').value.trim();
      }

      try {
        await callBridge('library.add', payload);
        showToast({ key: 'setupL.library.toastAdded' });
        closeModal();
        await refreshDashboard(true, true);
      } catch (e) {
        showToast({ key: 'setupL.library.toastAddFailed', params: { error: e.message } }, 'error');
      }
    });
  }

  async function renderMcpSection(target) {
    const thisGen = renderGeneration;
    const thisPage = state.currentPage;
    const thisScope = state.currentProject;

    let mcpArtifacts = ((state.dashboard && state.dashboard.artifacts) || []).filter(a => {
      const t = (a.type || '').toLowerCase();
      return t === 'mcp' || a.containsMCP === true;
    });

    function renderMcpArtifactsTable(artifacts) {
      const container = document.getElementById('mcp-artifacts-container');
      const countSpan = document.getElementById('mcp-scanned-count');
      if (!container) return;
      if (countSpan) {
        VelaI18n.setElementDescriptor(countSpan, { key: 'setupL.mcp.scannedCount', params: { count: artifacts.length } });
      }

      if (artifacts.length === 0) {
        container.innerHTML = `
          <div class="empty-state" style="padding: 24px 0;">
            <div class="empty-state-title" data-i18n="setupL.mcp.emptyTitle">${escapeHtml(t('setupL.mcp.emptyTitle'))}</div>
            <div class="empty-state-desc" data-i18n="setupL.mcp.emptyDesc">${escapeHtml(t('setupL.mcp.emptyDesc'))}</div>
          </div>
        `;
        return;
      }

      container.innerHTML = `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th data-i18n="setupL.table.titleOrId">${escapeHtml(t('setupL.table.titleOrId'))}</th>
                <th data-i18n="setupL.table.providerOrScope">${escapeHtml(t('setupL.table.providerOrScope'))}</th>
                <th data-i18n="setupL.table.estimatedTokens">${escapeHtml(t('setupL.table.estimatedTokens'))}</th>
                <th data-i18n="setupL.table.hash">${escapeHtml(t('setupL.table.hash'))}</th>
                <th data-i18n="setupL.table.diagnostics">${escapeHtml(t('setupL.table.diagnostics'))}</th>
                <th style="text-align: right; width: 140px;" data-i18n="setupL.table.actions">${escapeHtml(t('setupL.table.actions'))}</th>
              </tr>
            </thead>
            <tbody>
              ${artifacts.map(a => `
                <tr>
                  <td>
                    <strong>${escapeHtml(a.title || a.id)}</strong>
                    <div style="font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(a.path || '')}</div>
                  </td>
                  <td>
                    <span class="code-badge">${escapeHtml(a.provider || 'generic')}</span>
                    <span style="font-size: 12px; color: var(--text-secondary); margin-left: 4px;">${escapeHtml(a.scope || 'project')}</span>
                  </td>
                  <td><span class="font-mono">${escapeHtml(String(a.tokens || '-'))}</span></td>
                  <td><span class="font-mono" style="font-size: 12px;">${a.hash ? escapeHtml(a.hash.substring(0, 10)) : '-'}</span></td>
                  <td>
                    ${a.diagnostics && a.diagnostics.length > 0
                      ? `<span class="status-badge status-amber" data-i18n="setupL.artifacts.warningCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: a.diagnostics.length }))}">${escapeHtml(t('setupL.artifacts.warningCount', { count: a.diagnostics.length }))}</span>`
                      : `<span class="status-badge status-sage" data-i18n="setupL.artifacts.statusNormal">${escapeHtml(t('setupL.artifacts.statusNormal'))}</span>`}
                  </td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-preview-artifact" data-id="${escapeHtml(a.id)}" data-i18n="setupL.artifacts.preview">${escapeHtml(t('setupL.artifacts.preview'))}</button>
                    ${a.path ? `<button class="btn btn-ghost btn-sm btn-reveal-path" data-path="${escapeHtml(a.path)}" data-i18n="setupL.artifacts.reveal">${escapeHtml(t('setupL.artifacts.reveal'))}</button>` : ''}
                  </td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        </div>
      `;

      container.querySelectorAll('.btn-preview-artifact').forEach(btn => {
        btn.addEventListener('click', () => {
          const id = btn.getAttribute('data-id');
          const art = artifacts.find(a => a.id === id);
          if (art) {
            openDrawer(art.title || { key: 'setupL.mcp.drawerTitle' }, art.path);
            const drawerContent = document.getElementById('drawer-content');
            if (drawerContent) {
              drawerContent.innerHTML = `
                <div class="card">
                  <div class="card-header"><span class="card-title" data-i18n="setupL.drawer.basicInfo">${escapeHtml(t('setupL.drawer.basicInfo'))}</span></div>
                  <div style="font-size: 12px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                    <div><span class="text-secondary" data-i18n="setupL.drawer.type">${escapeHtml(t('setupL.drawer.type'))}</span> ${escapeHtml(art.type || 'mcp')}</div>
                    <div><span class="text-secondary" data-i18n="setupL.drawer.provider">${escapeHtml(t('setupL.drawer.provider'))}</span> ${escapeHtml(art.provider || '-')}</div>
                    <div><span class="text-secondary" data-i18n="setupL.drawer.tokens">${escapeHtml(t('setupL.drawer.tokens'))}</span> ${escapeHtml(String(art.tokens || '-'))}</div>
                    <div><span class="text-secondary" data-i18n="setupL.drawer.hash">${escapeHtml(t('setupL.drawer.hash'))}</span> <span class="font-mono">${escapeHtml(art.hash || '-')}</span></div>
                  </div>
                  <div style="margin-top: 8px; font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);"><span data-i18n="setupL.drawer.pathPrefix">${escapeHtml(t('setupL.drawer.pathPrefix'))}</span>: ${escapeHtml(art.path || '-')}</div>
                </div>
                <div>
                  <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;" data-i18n="setupL.drawer.readonlyPreview">${escapeHtml(t('setupL.drawer.readonlyPreview'))}</h3>
                  <div class="code-view">${art.content ? escapeHtml(art.content) : tHtml('setupL.drawer.noContent')}</div>
                </div>
              `;
            }
          }
        });
      });

      container.querySelectorAll('.btn-reveal-path').forEach(btn => {
        btn.addEventListener('click', async () => {
          const path = btn.getAttribute('data-path');
          try {
            await callBridge('system.reveal', { path });
          } catch (e) {
            showToast({ key: 'setupL.toast.revealFailed', params: { error: e.message } }, 'error');
          }
        });
      });
    }

    target.innerHTML = `
      <div class="card" style="margin-bottom: 20px;">
        <div class="card-header">
          <span class="card-title" data-i18n="setupL.mcp.cardTitle">${escapeHtml(t('setupL.mcp.cardTitle'))}</span>
          <span class="status-badge status-sage" data-i18n="setupL.mcp.badgeStdio">${escapeHtml(t('setupL.mcp.badgeStdio'))}</span>
        </div>
        <p style="font-size: 12px; color: var(--text-secondary); margin-bottom: 12px;" data-i18n="setupL.mcp.cardDesc">${escapeHtml(t('setupL.mcp.cardDesc'))}</p>

        <div class="alert-banner alert-info" style="margin-bottom: 12px;">
          <span>
            <strong data-i18n="setupL.mcp.securityConstraintLabel">${escapeHtml(t('setupL.mcp.securityConstraintLabel'))}</strong><span data-i18n="setupL.mcp.securityConstraintDesc1">${escapeHtml(t('setupL.mcp.securityConstraintDesc1'))}</span><strong data-i18n="setupL.mcp.securityConstraintDescStrong">${escapeHtml(t('setupL.mcp.securityConstraintDescStrong'))}</strong><span data-i18n="setupL.mcp.securityConstraintDesc2">${escapeHtml(t('setupL.mcp.securityConstraintDesc2'))}</span>
          </span>
        </div>

        <h4 style="font-size: 12px; font-weight: 600; margin-bottom: 6px;" data-i18n="setupL.mcp.exampleConfigTitle">${escapeHtml(t('setupL.mcp.exampleConfigTitle'))}</h4>
        <div class="code-view" style="margin-bottom: 12px;">{
  "mcpServers": {
    "vela": {
      "command": "vela",
      "args": ["mcp", "--home", "${escapeHtml(state.systemInfo.home)}"]
    }
  }
}</div>
      </div>

      <div class="section-title-group" style="margin-bottom: 12px;">
        <div style="display: flex; align-items: center; justify-content: space-between;">
          <h3 style="font-size: 13px; font-weight: 600; margin: 0;" data-i18n="setupL.mcp.scannedTitle">${escapeHtml(t('setupL.mcp.scannedTitle'))}</h3>
          <span id="mcp-scanned-count" class="text-secondary" style="font-size: 12px;" data-i18n="setupL.mcp.scannedCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: mcpArtifacts.length }))}">${escapeHtml(t('setupL.mcp.scannedCount', { count: mcpArtifacts.length }))}</span>
        </div>
        <p style="font-size: 12px; color: var(--text-secondary); margin-top: 4px;" data-i18n="setupL.mcp.scannedDesc">${escapeHtml(t('setupL.mcp.scannedDesc'))}</p>
      </div>

      <div id="mcp-artifacts-container"></div>
    `;

    renderMcpArtifactsTable(mcpArtifacts);

    try {
      const res = await callBridge('setup.list', state.currentProject ? { project: state.currentProject } : {});
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(target)) return;
      if (Array.isArray(res)) {
        const fetchedMcp = res.filter(a => {
          const t = (a.type || '').toLowerCase();
          return t === 'mcp' || a.containsMCP === true;
        });
        const mergedMap = new Map();
        mcpArtifacts.forEach(a => mergedMap.set(a.id || a.path, a));
        fetchedMcp.forEach(a => mergedMap.set(a.id || a.path, a));
        const mergedList = Array.from(mergedMap.values());
        renderMcpArtifactsTable(mergedList);
      }
    } catch (e) {
      // Keep existing rendered dashboard artifacts silently
    }
  }

  // -------------------------------------------------------------------------
  // 4. USAGE VIEW
  // -------------------------------------------------------------------------
  async function renderUsageView(container) {
    // Local helpers to avoid outer closure namespace expansion
    function isSafeCount(val) {
      return typeof val === 'number' && Number.isSafeInteger(val) && val >= 0;
    }

    function formatCount(val) {
      return isSafeCount(val) ? val.toLocaleString() : t('common.notProvided');
    }

    function formatDateLabel(rawDate) {
      if (!rawDate || typeof rawDate !== 'string') return '-';
      try {
        if (rawDate.length >= 10 && rawDate.charAt(4) === '-' && rawDate.charAt(7) === '-') {
          return rawDate.substring(5, 10);
        }
        const d = new Date(rawDate);
        if (!isNaN(d.getTime())) {
          const m = String(d.getMonth() + 1).padStart(2, '0');
          const day = String(d.getDate()).padStart(2, '0');
          return `${m}-${day}`;
        }
      } catch {}
      return String(rawDate).substring(0, 10);
    }

    function safeEscapeHtml(str) {
      if (typeof escapeHtml === 'function') {
        return escapeHtml(str);
      }
      if (str === null || str === undefined) return '';
      return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
    }

    function safeFormatProvider(provider) {
      if (typeof formatProviderName === 'function') {
        return formatProviderName(provider);
      }
      if (!provider) return t('usage.unknownProvider');
      const p = String(provider).toLowerCase();
      if (p === 'claude' || p === 'claude-code') return 'Claude Code';
      if (p === 'codex') return 'Codex';
      if (p === 'cursor') return 'Cursor';
      if (p === 'copilot') return 'GitHub Copilot';
      return provider;
    }

    const thisGen = renderGeneration;
    const thisPage = state.currentPage;
    const thisScope = state.currentProject;

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="usage.title">${t('usage.title')}</h1>
          <p data-i18n="usage.subtitle">${t('usage.subtitle')}</p>
        </div>
      </div>

      <div class="alert-banner alert-info" style="margin-bottom: 14px;">
        <span data-i18n="usage.observationNotice">${t('usage.observationNotice')}</span>
      </div>

      <div class="stat-grid" id="usage-stat-grid">
        <div class="stat-card">
          <div class="stat-label" data-i18n="usage.statTotalTokens">${t('usage.statTotalTokens')}</div>
          <div style="display: flex; align-items: baseline; gap: 6px;">
            <span class="stat-value" id="usage-total-tokens">-</span>
            <span id="usage-total-tokens-badge"></span>
          </div>
          <div class="stat-sub" id="usage-total-tokens-sub" data-i18n="usage.statTotalTokensSub">${t('usage.statTotalTokensSub')}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label" data-i18n="usage.statTotalSessions">${t('usage.statTotalSessions')}</div>
          <div class="stat-value" id="usage-total-sessions">-</div>
          <div class="stat-sub" id="usage-total-sessions-sub" data-i18n="usage.statTotalSessionsSub">${t('usage.statTotalSessionsSub')}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label" data-i18n="usage.statProviderCount">${t('usage.statProviderCount')}</div>
          <div class="stat-value" id="usage-provider-count">-</div>
          <div class="stat-sub" id="usage-provider-count-sub" data-i18n="usage.statProviderCountSub">${t('usage.statProviderCountSub')}</div>
        </div>
      </div>

      <div id="usage-coverage-note" class="alert-banner alert-info" style="margin-bottom: 14px; font-size: 12px; display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px;">
        <div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;">
          <span style="font-weight: 600;" data-i18n="usage.coverageStatusLabel">${t('usage.coverageStatusLabel')}</span>
          <span id="usage-coverage-badge" class="status-badge status-neutral" data-i18n="common.notProvided">${t('common.notProvided')}</span>
          <span id="usage-coverage-text" style="color: var(--text-main);" data-i18n="usage.noCoverageInfo">${t('usage.noCoverageInfo')}</span>
        </div>
        <div id="usage-coverage-details-wrap" style="display: none;">
          <details style="font-size: 11px;">
            <summary style="cursor: pointer; color: var(--text-muted); user-select: none;" data-i18n="usage.techDetails">${t('usage.techDetails')}</summary>
            <span id="usage-coverage-desc" class="code-badge" style="margin-top: 4px; display: inline-block;"></span>
          </details>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <span class="card-title" data-i18n="usage.providerDistributionTitle">${t('usage.providerDistributionTitle')}</span>
        </div>
        <div class="table-wrapper" style="margin-bottom: 0;">
          <table class="data-table">
            <thead>
              <tr>
                <th data-i18n="usage.thProvider">${t('usage.thProvider')}</th>
                <th data-i18n="usage.thInputTokens">${t('usage.thInputTokens')}</th>
                <th data-i18n="usage.thOutputTokens">${t('usage.thOutputTokens')}</th>
                <th data-i18n="usage.thTotalTokens">${t('usage.thTotalTokens')}</th>
                <th data-i18n="usage.thSessions">${t('usage.thSessions')}</th>
                <th data-i18n="usage.thCloudQuotaStatus">${t('usage.thCloudQuotaStatus')}</th>
              </tr>
            </thead>
            <tbody id="usage-provider-tbody"></tbody>
          </table>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title" data-i18n="usage.dailyTrendTitle">${t('usage.dailyTrendTitle')}</span>
        </div>
        <div id="usage-daily-container"></div>
      </div>
    `;

    try {
      const usage = await callBridge('usage.get', state.currentProject ? { project: state.currentProject } : {});
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(container)) return;

      if (usage) {
        // 1. Total tokens stat card: preserves clean textContent for tests
        const totalTokensEl = document.getElementById('usage-total-tokens');
        const totalTokensBadgeEl = document.getElementById('usage-total-tokens-badge');
        const totalTokensSubEl = document.getElementById('usage-total-tokens-sub');

        if (usage.coverage === 'overflow') {
          if (totalTokensEl) setElementDescriptor(totalTokensEl, { key: 'usage.overflow' });
          if (totalTokensBadgeEl) totalTokensBadgeEl.innerHTML = '';
          if (totalTokensSubEl) setElementDescriptor(totalTokensSubEl, { key: 'usage.overflowDesc' });
        } else if (isSafeCount(usage.totalTokens)) {
          if (totalTokensEl) setElementDescriptor(totalTokensEl, usage.totalTokens.toLocaleString());
          if (totalTokensBadgeEl) totalTokensBadgeEl.innerHTML = '';
          if (totalTokensSubEl) {
            const inStr = isSafeCount(usage.inputTokens) ? usage.inputTokens.toLocaleString() : '-';
            const outStr = isSafeCount(usage.outputTokens) ? usage.outputTokens.toLocaleString() : '-';
            setElementDescriptor(totalTokensSubEl, { key: 'usage.totalTokensFullSub', params: { in: inStr, out: outStr } });
          }
        } else if (isSafeCount(usage.observedTotalTokens)) {
          if (totalTokensEl) setElementDescriptor(totalTokensEl, usage.observedTotalTokens.toLocaleString());
          if (totalTokensBadgeEl) {
            totalTokensBadgeEl.innerHTML = `<span class="status-badge status-amber" style="font-size: 10px;" data-i18n="usage.badgeObservedPart">${t('usage.badgeObservedPart')}</span>`;
          }
          if (totalTokensSubEl) {
            const obsS = isSafeCount(usage.observedSessionCount) ? usage.observedSessionCount.toLocaleString() : '-';
            const missS = isSafeCount(usage.missingUsageSessionCount) ? usage.missingUsageSessionCount.toLocaleString() : '-';
            setElementDescriptor(totalTokensSubEl, { key: 'usage.observedMissSub', params: { observed: obsS, missing: missS } });
          }
        } else {
          if (totalTokensEl) setElementDescriptor(totalTokensEl, { key: 'common.notProvided' });
          if (totalTokensBadgeEl) totalTokensBadgeEl.innerHTML = '';
          if (totalTokensSubEl) {
            setElementDescriptor(totalTokensSubEl, { key: (usage.coverage === 'unavailable') ? 'usage.noTokenData' : 'usage.noCountData' });
          }
        }

        // 2. Session count stat card
        const sessionsEl = document.getElementById('usage-total-sessions');
        const sessionsSubEl = document.getElementById('usage-total-sessions-sub');
        if (sessionsEl) {
          setElementDescriptor(sessionsEl, formatCount(usage.sessionCount));
        }
        if (sessionsSubEl) {
          if (isSafeCount(usage.observedSessionCount) && isSafeCount(usage.missingUsageSessionCount)) {
            setElementDescriptor(sessionsSubEl, { key: 'usage.sessionsObservedMissSub', params: { observed: usage.observedSessionCount.toLocaleString(), missing: usage.missingUsageSessionCount.toLocaleString() } });
          } else if (isSafeCount(usage.observedSessionCount)) {
            setElementDescriptor(sessionsSubEl, { key: 'usage.sessionsObservedSub', params: { observed: usage.observedSessionCount.toLocaleString() } });
          } else {
            setElementDescriptor(sessionsSubEl, { key: 'usage.statTotalSessionsSub' });
          }
        }

        // 3. Provider count stat card
        const providers = Array.isArray(usage.providers) ? usage.providers : [];
        const provCountEl = document.getElementById('usage-provider-count');
        const provCountSubEl = document.getElementById('usage-provider-count-sub');
        if (provCountEl) {
          setElementDescriptor(provCountEl, providers.length.toLocaleString());
        }
        if (provCountSubEl) {
          setElementDescriptor(provCountSubEl, { key: 'usage.statProviderCountSub' });
        }

        // 4. Coverage status note
        const covBadge = document.getElementById('usage-coverage-badge');
        const covText = document.getElementById('usage-coverage-text');
        const covDetailsWrap = document.getElementById('usage-coverage-details-wrap');
        const covDesc = document.getElementById('usage-coverage-desc');

        if (covBadge && covText) {
          if (usage.coverage === 'complete') {
            covBadge.className = 'status-badge status-sage';
            setElementDescriptor(covBadge, { key: 'usage.covComplete' });
            setElementDescriptor(covText, { key: 'usage.covCompleteText' });
          } else if (usage.coverage === 'partial') {
            covBadge.className = 'status-badge status-amber';
            setElementDescriptor(covBadge, { key: 'usage.covPartial' });
            const obs = isSafeCount(usage.observedSessionCount) ? usage.observedSessionCount.toLocaleString() : '-';
            const miss = isSafeCount(usage.missingUsageSessionCount) ? usage.missingUsageSessionCount.toLocaleString() : '-';
            setElementDescriptor(covText, { key: 'usage.covPartialText', params: { observed: obs, missing: miss } });
          } else if (usage.coverage === 'overflow') {
            covBadge.className = 'status-badge status-red';
            setElementDescriptor(covBadge, { key: 'usage.covOverflow' });
            setElementDescriptor(covText, { key: 'usage.covOverflowText' });
          } else if (usage.coverage === 'unavailable') {
            covBadge.className = 'status-badge status-neutral';
            setElementDescriptor(covBadge, { key: 'usage.covUnavailable' });
            setElementDescriptor(covText, { key: 'usage.covUnavailableText' });
          } else {
            covBadge.className = 'status-badge status-neutral';
            setElementDescriptor(covBadge, { key: 'common.notProvided' });
            setElementDescriptor(covText, { key: 'usage.covDefaultText' });
          }
        }

        if (covDetailsWrap && covDesc) {
          if (usage.coverageDescription && typeof usage.coverageDescription === 'string') {
            covDesc.textContent = usage.coverageDescription;
            covDetailsWrap.style.display = 'block';
          } else {
            covDetailsWrap.style.display = 'none';
          }
        }

        // 5. Provider distribution table
        const tbody = document.getElementById('usage-provider-tbody');
        if (tbody) {
          if (providers.length === 0) {
            tbody.innerHTML = `<tr><td colspan="6" style="text-align:center; color:var(--text-muted); padding:20px;" data-i18n="usage.noTableData">${t('usage.noTableData')}</td></tr>`;
          } else {
            tbody.innerHTML = providers.map(p => {
              const rawName = p.provider || '';
              const displayName = safeFormatProvider(rawName);
              const nameHtml = (displayName !== rawName && rawName)
                ? `<strong>${safeEscapeHtml(displayName)}</strong> <span class="code-badge" style="margin-left:4px; font-weight:normal;">${safeEscapeHtml(rawName)}</span>`
                : `<strong>${safeEscapeHtml(displayName || t('usage.unknownProvider'))}</strong>`;

              // Input tokens: missing count remains '未提供', aggregate overflow does not mark dimension as overflow
              let inputHtml = `<span style="color:var(--text-muted);" data-i18n="common.notProvided">${t('common.notProvided')}</span>`;
              if (isSafeCount(p.inputTokens)) {
                inputHtml = p.inputTokens.toLocaleString();
              } else if (isSafeCount(p.observedInputTokens)) {
                inputHtml = `${p.observedInputTokens.toLocaleString()} <span class="status-badge status-amber" style="font-size:9px; padding:1px 4px;" data-i18n="usage.badgeObservedPart">${t('usage.badgeObservedPart')}</span>`;
              }

              // Output tokens: missing count remains '未提供', aggregate overflow does not mark dimension as overflow
              let outputHtml = `<span style="color:var(--text-muted);" data-i18n="common.notProvided">${t('common.notProvided')}</span>`;
              if (isSafeCount(p.outputTokens)) {
                outputHtml = p.outputTokens.toLocaleString();
              } else if (isSafeCount(p.observedOutputTokens)) {
                outputHtml = `${p.observedOutputTokens.toLocaleString()} <span class="status-badge status-amber" style="font-size:9px; padding:1px 4px;" data-i18n="usage.badgeObservedPart">${t('usage.badgeObservedPart')}</span>`;
              }

              // Total tokens: explains aggregate overflow if applicable
              let totalHtml = `<span style="color:var(--text-muted);" data-i18n="common.notProvided">${t('common.notProvided')}</span>`;
              if (isSafeCount(p.totalTokens)) {
                totalHtml = `<strong>${p.totalTokens.toLocaleString()}</strong>`;
              } else if (isSafeCount(p.observedTotalTokens)) {
                totalHtml = `<strong>${p.observedTotalTokens.toLocaleString()}</strong> <span class="status-badge status-amber" style="font-size:9px; padding:1px 4px;" data-i18n="usage.badgeObservedPart">${t('usage.badgeObservedPart')}</span>`;
              } else if (p.coverage === 'overflow') {
                totalHtml = `<span class="status-badge status-red" style="font-size:9px;" data-i18n="usage.badgeOutOfRange">${t('usage.badgeOutOfRange')}</span>`;
              }

              let sessionHtml = `<span style="color:var(--text-muted);" data-i18n="common.notProvided">${t('common.notProvided')}</span>`;
              if (isSafeCount(p.sessionCount)) {
                if (isSafeCount(p.observedSessionCount) && isSafeCount(p.missingUsageSessionCount)) {
                  sessionHtml = `${p.sessionCount.toLocaleString()} <div style="font-size:10px; color:var(--text-muted); line-height:1.2;">${t('usage.tableSessionObsMiss', { observed: p.observedSessionCount.toLocaleString(), missing: p.missingUsageSessionCount.toLocaleString() })}</div>`;
                } else {
                  sessionHtml = p.sessionCount.toLocaleString();
                }
              }

              const quotaHtml = (p.quotaAvailable && typeof p.quota === 'string' && p.quota)
                ? `<span class="status-badge status-neutral">${safeEscapeHtml(p.quota)}</span>`
                : `<span class="status-badge status-neutral" title="${t('usage.quotaTooltip')}" data-i18n-title="usage.quotaTooltip" data-i18n="common.notProvided">${t('common.notProvided')}</span>`;

              return `
                <tr>
                  <td>${nameHtml}</td>
                  <td class="font-mono">${inputHtml}</td>
                  <td class="font-mono">${outputHtml}</td>
                  <td class="font-mono">${totalHtml}</td>
                  <td>${sessionHtml}</td>
                  <td>${quotaHtml}</td>
                </tr>
              `;
            }).join('');
          }
        }

        // 6. Daily trend chart
        const daily = Array.isArray(usage.daily) ? usage.daily : [];
        const dailyCont = document.getElementById('usage-daily-container');
        if (dailyCont) {
          if (daily.length === 0) {
            dailyCont.innerHTML = `<div style="font-size:11px; color:var(--text-muted); padding:16px 0; text-align:center;" data-i18n="usage.noDailyData">${t('usage.noDailyData')}</div>`;
          } else {
            const recentDays = daily.slice(-14);
            const NUMERIC_PLOT_HEIGHT = 100;

            const dayMetrics = recentDays.map(d => {
              let countType = 'unknown'; // 'complete' | 'observed' | 'complete_zero' | 'observed_zero' | 'unknown' | 'overflow'
              let plotCount = null;
              let tooltip = '';

              const hasCompleteTokens = isSafeCount(d.tokens) || isSafeCount(d.totalTokens);
              const completeVal = isSafeCount(d.tokens) ? d.tokens : (isSafeCount(d.totalTokens) ? d.totalTokens : null);
              const hasObservedTokens = isSafeCount(d.observedTokens) || isSafeCount(d.observedTotalTokens);
              const observedVal = isSafeCount(d.observedTokens) ? d.observedTokens : (isSafeCount(d.observedTotalTokens) ? d.observedTotalTokens : null);

              const obsS = isSafeCount(d.observedSessionCount) ? d.observedSessionCount.toLocaleString() : t('common.notProvided');
              const missS = isSafeCount(d.missingUsageSessionCount) ? d.missingUsageSessionCount.toLocaleString() : t('common.notProvided');
              const dateText = safeEscapeHtml(d.date || t('common.unknownDate'));

              if (d.coverage === 'overflow') {
                countType = 'overflow';
                tooltip = t('usage.chartOverflowTooltip', { date: dateText });
              } else if (hasCompleteTokens) {
                plotCount = completeVal;
                if (plotCount === 0) {
                  countType = 'complete_zero';
                  tooltip = t('usage.chartCompleteZeroTooltip', { date: dateText });
                } else {
                  countType = 'complete';
                  tooltip = t('usage.chartCompleteTooltip', { date: dateText, tokens: plotCount.toLocaleString() });
                }
              } else if (hasObservedTokens) {
                plotCount = observedVal;
                if (plotCount === 0) {
                  countType = 'observed_zero';
                  tooltip = t('usage.chartObservedZeroTooltip', { date: dateText, observed: obsS, missing: missS });
                } else {
                  countType = 'observed';
                  tooltip = t('usage.chartObservedTooltip', { date: dateText, tokens: plotCount.toLocaleString(), observed: obsS, missing: missS });
                }
              } else {
                countType = 'unknown';
                tooltip = t('usage.chartUnknownTooltip', { date: dateText });
              }

              return {
                rawDate: d.date || '',
                dateLabel: formatDateLabel(d.date),
                countType,
                plotCount,
                tooltip
              };
            });

            let maxTokens = 0;
            for (const item of dayMetrics) {
              if (item.plotCount !== null && item.plotCount > maxTokens) {
                maxTokens = item.plotCount;
              }
            }

            dailyCont.innerHTML = `
              <div style="display: flex; align-items: flex-end; gap: 8px; padding-bottom: 2px; border-bottom: 1px solid var(--border-color); box-sizing: border-box;">
                ${dayMetrics.map(item => {
                  let topLabelHtml = '';
                  let barOrMarkerHtml = '';

                  if (item.countType === 'complete' && maxTokens > 0) {
                    const barHeightPx = (item.plotCount / maxTokens) * NUMERIC_PLOT_HEIGHT;
                    barOrMarkerHtml = `<div style="width: 100%; max-width: 32px; height: ${barHeightPx.toFixed(2)}px; background: var(--text-main); border-radius: 2px 2px 0 0;"></div>`;
                  } else if (item.countType === 'observed' && maxTokens > 0) {
                    const barHeightPx = (item.plotCount / maxTokens) * NUMERIC_PLOT_HEIGHT;
                    topLabelHtml = `<span style="font-size: 8px; font-family: var(--font-mono); color: var(--status-amber-text); white-space: nowrap;" data-i18n="usage.chartObservedLabel">${t('usage.chartObservedLabel')}</span>`;
                    barOrMarkerHtml = `<div style="width: 100%; max-width: 32px; height: ${barHeightPx.toFixed(2)}px; background: var(--status-amber-text); border-radius: 2px 2px 0 0; opacity: 0.9;"></div>`;
                  } else if (item.countType === 'complete_zero') {
                    topLabelHtml = `<span style="font-size: 8px; font-family: var(--font-mono); color: var(--text-muted); white-space: nowrap;">0</span>`;
                    barOrMarkerHtml = `<div style="width: 100%; max-width: 32px; height: 2px; background: var(--text-muted); border-radius: 1px;"></div>`;
                  } else if (item.countType === 'observed_zero') {
                    topLabelHtml = `<span style="font-size: 8px; font-family: var(--font-mono); color: var(--status-amber-text); white-space: nowrap;" data-i18n="usage.chartObservedZeroLabel">${t('usage.chartObservedZeroLabel')}</span>`;
                    barOrMarkerHtml = `<div style="width: 100%; max-width: 32px; height: 2px; background: var(--status-amber-text); border-radius: 1px;"></div>`;
                  } else if (item.countType === 'overflow') {
                    topLabelHtml = `<span style="font-size: 8px; font-family: var(--font-mono); color: var(--status-red-text); white-space: nowrap;" data-i18n="usage.chartOverflowLabel">${t('usage.chartOverflowLabel')}</span>`;
                    barOrMarkerHtml = `<div style="width: 100%; max-width: 24px; height: 1px; border-bottom: 1px dashed var(--status-red-border);"></div>`;
                  } else {
                    topLabelHtml = `<span style="font-size: 8px; font-family: var(--font-mono); color: var(--text-muted); white-space: nowrap;" data-i18n="common.notProvided">${t('common.notProvided')}</span>`;
                    barOrMarkerHtml = `<div style="width: 100%; max-width: 24px; height: 1px; border-bottom: 1px dashed var(--border-color);"></div>`;
                  }

                  return `
                    <div style="flex: 1; min-width: 0; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; box-sizing: border-box;" title="${item.tooltip}">
                      <div style="height: 16px; display: flex; align-items: flex-end; justify-content: center; margin-bottom: 2px; width: 100%;">
                        ${topLabelHtml}
                      </div>
                      <div style="height: ${NUMERIC_PLOT_HEIGHT}px; width: 100%; display: flex; flex-direction: column; align-items: center; justify-content: flex-end;">
                        ${barOrMarkerHtml}
                      </div>
                    </div>
                  `;
                }).join('')}
              </div>

              <div style="display: flex; gap: 8px; padding-top: 6px;">
                ${dayMetrics.map(item => `
                  <div style="flex: 1; min-width: 0; text-align: center;">
                    <span style="font-size: 9px; font-family: var(--font-mono); color: var(--text-muted); display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title="${safeEscapeHtml(item.rawDate)}">
                      ${safeEscapeHtml(item.dateLabel)}
                    </span>
                  </div>
                `).join('')}
              </div>

              <div style="display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; margin-top: 10px; padding-top: 8px; border-top: 1px solid var(--border-subtle); font-size: 11px; color: var(--text-muted);">
                <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
                  <span style="display: inline-flex; align-items: center; gap: 4px;">
                    <span style="display: inline-block; width: 10px; height: 10px; background: var(--text-main); border-radius: 2px;"></span>
                    <span data-i18n="usage.legendComplete">${t('usage.legendComplete')}</span>
                  </span>
                  <span style="display: inline-flex; align-items: center; gap: 4px;">
                    <span style="display: inline-block; width: 10px; height: 10px; background: var(--status-amber-text); border-radius: 2px; opacity: 0.9;"></span>
                    <span data-i18n="usage.legendObserved">${t('usage.legendObserved')}</span>
                  </span>
                  <span style="display: inline-flex; align-items: center; gap: 4px;">
                    <span style="display: inline-block; width: 10px; height: 2px; background: var(--text-muted);"></span>
                    <span data-i18n="usage.legendZeroComplete">${t('usage.legendZeroComplete')}</span>
                  </span>
                  <span style="display: inline-flex; align-items: center; gap: 4px;">
                    <span style="display: inline-block; width: 10px; height: 2px; background: var(--status-amber-text);"></span>
                    <span data-i18n="usage.legendZeroObserved">${t('usage.legendZeroObserved')}</span>
                  </span>
                  <span style="display: inline-flex; align-items: center; gap: 4px;">
                    <span style="display: inline-block; width: 10px; height: 0; border-bottom: 1px dashed var(--border-color);"></span>
                    <span data-i18n="usage.legendUnavailable">${t('usage.legendUnavailable')}</span>
                  </span>
                </div>
                <span data-i18n="usage.chartFooterNote">${t('usage.chartFooterNote')}</span>
              </div>
            `;
          }
        }
      }
    } catch (err) {
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(container)) return;
      const grid = document.getElementById('usage-stat-grid');
      if (grid) {
        grid.innerHTML = `
          <div class="alert-banner alert-danger" style="grid-column: 1 / -1;">
            ${t('usage.loadError', { error: safeEscapeHtml(err && err.message ? err.message : String(err)) })}
          </div>
        `;
      }
    }
  }

  // -------------------------------------------------------------------------
  // 5. IMPROVE VIEW (Real backend preview shape)
  // -------------------------------------------------------------------------
  function renderImproveView(container) {
    const suggestions = (state.dashboard && state.dashboard.suggestions) || [];

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="improve.title">${t('improve.title')}</h1>
          <p data-i18n="improve.subtitle">${t('improve.subtitle')}</p>
        </div>
        <div class="page-actions">
          <button id="btn-run-analysis" class="btn btn-primary btn-sm" data-i18n="improve.btnRunAnalysis">${t('improve.btnRunAnalysis')}</button>
        </div>
      </div>

      <div class="improve-methodology-note" role="note">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg>
        <span data-i18n="improve.methodologyNote">${t('improve.methodologyNote')}</span>
      </div>

      <div class="improve-container">
        ${suggestions.length === 0 ? `
          <div class="empty-state">
            <div class="empty-state-title" data-i18n="improve.emptyTitle">${t('improve.emptyTitle')}</div>
            <div class="empty-state-desc" data-i18n="improve.emptyDesc">${t('improve.emptyDesc')}</div>
          </div>
        ` : `
          <ul class="improve-card-list" role="list">
            ${suggestions.map(sug => {
              const st = (sug.state || 'pending').toLowerCase();
              const evList = sug.evidence || [];
              const distinctSessions = new Set(evList.map(e => e.sessionId).filter(Boolean)).size;
              const evCount = evList.length;

              let bodyHtml = '';
              let rawBodyText = sug.description || sug.issue || sug.reason || '';
              if (rawBodyText) {
                bodyHtml = `<div class="improve-card-body">${escapeHtml(rawBodyText)}</div>`;
              } else if (evList.length > 0) {
                bodyHtml = `<div class="improve-card-body" data-i18n="improve.fallbackBodyWithEvidence">${t('improve.fallbackBodyWithEvidence')}</div>`;
              } else {
                bodyHtml = `<div class="improve-card-body" data-i18n="improve.fallbackBodyDefault">${t('improve.fallbackBodyDefault')}</div>`;
              }

              const carrierBadge = sug.carrier
                ? `<span class="carrier-badge">${escapeHtml(sug.carrier)}</span>`
                : `<span class="carrier-badge" data-i18n="improve.defaultCarrier">${t('improve.defaultCarrier')}</span>`;

              const candidateCount = sug.verificationCandidateMemoryIds ? sug.verificationCandidateMemoryIds.length : 0;
              const candParams = JSON.stringify({ count: candidateCount });

              return `
                <li class="improve-card" data-id="${escapeHtml(sug.id)}">
                  <div class="improve-card-header">
                    <div class="improve-card-title">${escapeHtml(sug.title || t('improve.title'))}</div>
                    ${distinctSessions > 0 ? `
                      <span class="evidence-count-badge" data-i18n="improve.evidenceLabelWithSessions" data-i18n-params="${escapeHtml(JSON.stringify({ count: evCount, sessions: distinctSessions }))}">${t('improve.evidenceLabelWithSessions', { count: evCount, sessions: distinctSessions })}</span>
                    ` : `
                      <span class="evidence-count-badge" data-i18n="improve.evidenceLabel" data-i18n-params="${escapeHtml(JSON.stringify({ count: evCount }))}">${t('improve.evidenceLabel', { count: evCount })}</span>
                    `}
                  </div>

                  ${bodyHtml}

                  <div class="improve-card-tags">
                    ${carrierBadge}
                    ${renderDiscoveryKindBadge(sug.discoveryKind)}
                    ${isAlreadyInstalledHook(sug) ? `<span class="status-badge status-sage" data-i18n="improve.hookConfigured">${t('improve.hookConfigured')}</span>` : ''}
                    ${candidateCount > 0 ? `<span class="badge-subtle" data-i18n="improve.candidateMemoriesBadge" data-i18n-params="${escapeHtml(candParams)}" data-i18n-title="improve.candidateMemoriesTooltip" title="${t('improve.candidateMemoriesTooltip', { count: candidateCount })}">${t('improve.candidateMemoriesBadge', { count: candidateCount })}</span>` : ''}
                    ${sug.contextTokens ? `<span class="badge-subtle font-mono">~${escapeHtml(String(sug.contextTokens))} tokens</span>` : ''}
                    ${getImproveStateBadge(st)}
                  </div>

                  ${renderAlreadyInstalledNotice(sug)}
                  ${renderProviderTrustNotice(sug, st === 'applied')}

                  <div class="improve-card-footer">
                    <div class="improve-footer-left">
                      ${sug.workflowDraft ? `<button class="btn btn-ghost btn-sm btn-view-workflow-draft" data-id="${escapeHtml(sug.id)}" data-i18n-title="improve.btnViewWorkflowDraftTitle" title="${t('improve.btnViewWorkflowDraftTitle')}" data-i18n="improve.btnViewWorkflowDraft">${t('improve.btnViewWorkflowDraft')}</button>` : ''}
                    </div>
                    <div class="improve-footer-right">
                      <button class="btn btn-secondary btn-sm btn-test-sug" data-id="${escapeHtml(sug.id)}" data-i18n-title="improve.btnTestSuggestionTitle" title="${t('improve.btnTestSuggestionTitle')}" data-i18n="improve.btnTestSuggestion">${t('improve.btnTestSuggestion')}</button>
                      <button class="btn btn-secondary btn-sm btn-preview-diff" data-id="${escapeHtml(sug.id)}" data-i18n="improve.btnPreviewDiff">${t('improve.btnPreviewDiff')}</button>
                      ${st === 'applied' ? `<button class="btn btn-ghost btn-sm btn-undo-sug" data-id="${escapeHtml(sug.id)}" data-i18n="improve.btnUndo">${t('improve.btnUndo')}</button>` : ''}
                      ${st !== 'applied' && st !== 'dismissed' ? `<button class="btn btn-ghost btn-sm btn-dismiss-sug" data-id="${escapeHtml(sug.id)}" data-i18n="improve.btnDismiss">${t('improve.btnDismiss')}</button>` : ''}
                    </div>
                  </div>
                </li>
              `;
            }).join('')}
          </ul>
        `}
      </div>
    `;

    document.getElementById('btn-run-analysis').addEventListener('click', async () => {
      try {
        showToast({ key: 'improve.analyzingEvidence' });
        const result = await callBridge('improve.analyze', state.currentProject ? { project: state.currentProject } : {});
        const sugCount = (result && result.suggestions && result.suggestions.length) || 0;
        const candCount = (result && result.candidateMemories && result.candidateMemories.length) || 0;
        if (candCount > 0) {
          showToast({ key: 'improve.analyzeDoneWithCandidates', params: { sugCount, candCount } });
        } else {
          showToast({ key: 'improve.analyzeDone', params: { sugCount } });
        }
        await refreshDashboard(true, true);
      } catch (e) {
        showToast({ key: 'improve.analyzeFailed', params: { error: e.message } }, 'error');
      }
    });

    container.querySelectorAll('.btn-test-sug').forEach(btn => {
      btn.addEventListener('click', () => {
        handleTestSuggestion(btn.getAttribute('data-id'));
      });
    });

    container.querySelectorAll('.btn-view-workflow-draft').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        const sug = suggestions.find(s => s.id === id);
        if (sug && sug.workflowDraft) {
          openEditWorkflowModal(sug.workflowDraft);
        }
      });
    });

    container.querySelectorAll('.btn-preview-diff').forEach(btn => {
      btn.addEventListener('click', () => {
        openImprovePreviewDrawer(btn.getAttribute('data-id'));
      });
    });

    container.querySelectorAll('.btn-undo-sug').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-id');
        try {
          await callBridge('improve.undo', { id });
          showToast({ key: 'improve.undoSuccess' });
          await refreshDashboard(true, true);
        } catch (e) {
          showToast({ key: 'improve.undoFailed', params: { error: e.message } }, 'error');
        }
      });
    });

    container.querySelectorAll('.btn-dismiss-sug').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-id');
        try {
          await callBridge('improve.dismiss', { id });
          showToast({ key: 'improve.dismissSuccess' });
          await refreshDashboard(true, true);
        } catch (e) {
          showToast({ key: 'improve.dismissFailed', params: { error: e.message } }, 'error');
        }
      });
    });
  }

  function getImproveStateBadge(st) {
    const s = (st || '').toLowerCase();
    switch (s) {
      case 'applied':
        return `<span class="status-badge status-sage" data-i18n="improve.stateApplied">✓ ${t('improve.stateApplied')}</span>`;
      case 'pending':
      case 'ready':
        return `<span class="status-badge status-amber" data-i18n="improve.statePending">${t('improve.statePending')}</span>`;
      case 'dismissed':
        return `<span class="status-badge status-neutral" data-i18n="improve.stateDismissed">${t('improve.stateDismissed')}</span>`;
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(st || t('improve.statePending'))}</span>`;
    }
  }

  let testSuggestionSequence = 0;

  function normalizeToRelativePath(filePath, projectRoot) {
    if (!filePath || typeof filePath !== 'string' || !projectRoot) return null;
    const normRoot = projectRoot.endsWith('/') ? projectRoot : (projectRoot + '/');
    let rel = filePath;
    if (filePath.startsWith('/')) {
      if (!filePath.startsWith(normRoot)) {
        return null;
      }
      rel = filePath.slice(normRoot.length);
    }
    while (rel.startsWith('/')) rel = rel.slice(1);
    if (!rel) return null;
    const parts = rel.split('/');
    if (parts.includes('..') || parts.includes('.')) {
      return null;
    }
    return rel;
  }

  async function handleTestSuggestion(suggestionId, preloadedPreviewObj = null) {
    const thisSeq = ++testSuggestionSequence;
    const thisProject = state.currentProject;
    const thisPage = state.currentPage;
    const initialModalInstance = currentModalInstance;

    let previewObj = preloadedPreviewObj;
    if (!previewObj) {
      try {
        showToast({ key: 'improve.testPreparing' }, 'info');
        previewObj = await callBridge('improve.preview', { id: suggestionId });
      } catch (err) {
        if (thisSeq !== testSuggestionSequence || state.currentProject !== thisProject || state.currentPage !== thisPage) return;
        showToast({ key: 'improve.testLoadFailed', params: { error: err.message } }, 'error');
        return;
      }
    }

    if (thisSeq !== testSuggestionSequence || state.currentProject !== thisProject || state.currentPage !== thisPage) {
      return;
    }
    const modal = document.getElementById('modal-container');
    const isModalOpen = modal && !modal.classList.contains('hidden');
    if (isModalOpen && currentModalInstance !== initialModalInstance) {
      return;
    }

    const suggestions = (state.dashboard && state.dashboard.suggestions) || [];
    const sug = suggestions.find(s => s.id === suggestionId);
    const targetProject = (sug && sug.project) || (previewObj && previewObj.project) || state.currentProject;
    const candidateMemoryIds = (sug && sug.verificationCandidateMemoryIds) || (previewObj && previewObj.verificationCandidateMemoryIds) || [];
    const ops = (previewObj && (previewObj.preview || previewObj.operations)) || (sug && sug.operations) || [];

    let fileCandidateValid = true;
    let fileCandidateUnsupportedReason = '';
    const candidateFiles = [];

    if (ops.length > 0) {
      for (const op of ops) {
        if (op.delete) {
          fileCandidateValid = false;
          fileCandidateUnsupportedReason = t('improve.unsupportedDelete');
          break;
        }
        const relPath = normalizeToRelativePath(op.path, targetProject);
        if (!relPath) {
          fileCandidateValid = false;
          fileCandidateUnsupportedReason = t('improve.unsupportedPath', { path: op.path });
          break;
        }
        const content = op.content !== undefined ? op.content : op.after;
        if (typeof content !== 'string') {
          fileCandidateValid = false;
          fileCandidateUnsupportedReason = t('improve.unsupportedNoContent', { path: op.path });
          break;
        }
        candidateFiles.push({
          path: relPath,
          content: content
        });
      }
    } else {
      fileCandidateValid = false;
    }

    const hasLinkedMemories = candidateMemoryIds.length > 0;
    let chosenKind = 'context';
    let chosenCandidateMemoryIds = [];
    let chosenCandidateFiles = [];
    let candidateExplanation = '';

    if (hasLinkedMemories) {
      chosenKind = 'memory';
      chosenCandidateMemoryIds = candidateMemoryIds;
      chosenCandidateFiles = [];
      candidateExplanation = t('improve.explanationMemoryCandidate', { count: candidateMemoryIds.length });
      if (fileCandidateValid && candidateFiles.length > 0) {
        candidateExplanation += t('improve.explanationMemoryExtraFiles', { count: candidateFiles.length });
      }
    } else if (fileCandidateValid && candidateFiles.length > 0) {
      chosenKind = 'context';
      chosenCandidateMemoryIds = [];
      chosenCandidateFiles = candidateFiles;
      candidateExplanation = t('improve.explanationFiles', { count: candidateFiles.length });
    } else {
      if (fileCandidateUnsupportedReason) {
        showToast({ key: 'improve.cannotTestReason', params: { reason: fileCandidateUnsupportedReason } }, 'error');
      } else {
        showToast({ key: 'improve.cannotTestNoContent' }, 'error');
      }
      return;
    }

    const sugTitle = (sug && sug.title) || (previewObj && previewObj.title) || suggestionId.slice(0, 8);
    openCreateLabModal({
      sourceSuggestionId: suggestionId,
      project: targetProject,
      title: t('improve.labModalTitle', { title: sugTitle }),
      kind: chosenKind,
      mode: 'codex_agent',
      candidateMemoryIds: chosenCandidateMemoryIds,
      candidateFiles: chosenCandidateFiles,
      candidateExplanation: candidateExplanation,
      baselineFiles: [],
      baselineMemoryIds: []
    });
  }

  let improvePreviewSequence = 0;

  async function openImprovePreviewDrawer(suggestionId) {
    const thisSeq = ++improvePreviewSequence;
    const thisProject = state.currentProject;
    const thisPage = state.currentPage;
    state.selectedSuggestionId = suggestionId;
    openDrawer({ key: 'improve.loadingDiff' }, { key: 'improve.title' });
    const thisDrawer = currentDrawerInstance;

    try {
      const previewObj = await callBridge('improve.preview', { id: suggestionId });
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== improvePreviewSequence || thisDrawer !== currentDrawerInstance || state.selectedSuggestionId !== suggestionId || !isDrawerOpen || state.currentProject !== thisProject || state.currentPage !== thisPage) {
        return;
      }

      if (!previewObj) {
        const e = new Error('improve.suggestionNotFound');
        e.i18nKey = 'improve.suggestionNotFound';
        throw e;
      }

      const titleDesc = previewObj.title ? previewObj.title : { key: 'improve.suggestionDetail' };
      const subDesc = suggestionId
        ? { key: 'improve.suggestionIdSubtitle', params: { id: suggestionId.substring(0, 8) } }
        : { key: 'improve.title' };
      setDrawerTitle(titleDesc, subDesc);

      const isApplied = (previewObj.state || '').toLowerCase() === 'applied';
      const isAlreadyConfigured = isAlreadyInstalledHook(previewObj);
      let actionButtons = `<button id="btn-drawer-test-sug" class="btn btn-secondary btn-sm" data-i18n="improve.btnTestSuggestion">${t('improve.btnTestSuggestion')}</button>`;
      if (isApplied) {
        actionButtons += `<button id="btn-drawer-undo-sug" class="btn btn-danger btn-sm" data-i18n="improve.btnUndoChanges">${t('improve.btnUndoChanges')}</button>`;
      } else if (!isAlreadyConfigured) {
        actionButtons += `<button id="btn-drawer-apply-sug" class="btn btn-primary btn-sm" data-i18n="improve.btnConfirmApply">${t('improve.btnConfirmApply')}</button>`;
      }
      setDrawerCustomActions(actionButtons);

      if (document.getElementById('btn-drawer-test-sug')) {
        document.getElementById('btn-drawer-test-sug').addEventListener('click', () => {
          handleTestSuggestion(suggestionId, previewObj);
        });
      }
      if (document.getElementById('btn-drawer-apply-sug')) {
        document.getElementById('btn-drawer-apply-sug').addEventListener('click', () => {
          openConfirmApplyModal(previewObj);
        });
      }
      if (document.getElementById('btn-drawer-undo-sug')) {
        document.getElementById('btn-drawer-undo-sug').addEventListener('click', async () => {
          try {
            await callBridge('improve.undo', { id: suggestionId });
            showToast({ key: 'improve.undoSuccess' });
            closeDrawer();
            await refreshDashboard(true, true);
          } catch (e) {
            showToast({ key: 'improve.undoFailed', params: { error: e.message } }, 'error');
          }
        });
      }

      // Authoritative preview shape: preview: [{ path, before, beforeHash, content, afterHash, delete }]
      const previewList = previewObj.preview || previewObj.operations || [];
      const evidenceList = previewObj.evidence || [];
      const drawerBody = document.getElementById('drawer-content');

      const candMemCount = (previewObj.verificationCandidateMemoryIds && previewObj.verificationCandidateMemoryIds.length) || 0;
      const candMemParams = JSON.stringify({ count: candMemCount });

      drawerBody.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title" data-i18n="improve.metaTitle">${t('improve.metaTitle')}</span>
            ${getImproveStateBadge(previewObj.state)}
          </div>
          <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
            <div><span class="text-secondary" data-i18n="improve.targetCarrier">${t('improve.targetCarrier')}:</span> <strong>${escapeHtml(previewObj.carrier || t('improve.defaultCarrier'))}</strong></div>
            <div><span class="text-secondary" data-i18n="improve.impactTokens">${t('improve.impactTokens')}:</span> ${previewObj.contextTokens ? '~' + escapeHtml(String(previewObj.contextTokens)) : '-'}</div>
            ${previewObj.discoveryKind ? `<div><span class="text-secondary" data-i18n="improve.discoveryKind">${t('improve.discoveryKind')}:</span> ${renderDiscoveryKindInline(previewObj.discoveryKind)}</div>` : ''}
            ${candMemCount > 0 ? `
              <details style="grid-column: 1 / -1; margin-top: 4px; font-size: 11px;">
                <summary style="cursor: pointer; color: var(--text-secondary);" data-i18n="improve.candidateMemoriesSummary" data-i18n-params="${escapeHtml(candMemParams)}">${t('improve.candidateMemoriesSummary', { count: candMemCount })}</summary>
                <ul style="margin-top: 4px; padding-left: 18px; font-family: var(--font-mono); font-size: 10.5px; color: var(--text-muted);">
                  ${previewObj.verificationCandidateMemoryIds.map(id => `<li>${escapeHtml(id)}</li>`).join('')}
                </ul>
              </details>
            ` : ''}
          </div>
          ${previewObj.workflowDraft ? `
            <div style="margin-top: 10px; padding-top: 8px; border-top: 1px dashed var(--border-color);">
              <button id="btn-drawer-inspect-wf" class="btn btn-ghost btn-sm" data-i18n="improve.btnInspectWorkflowDraft">${t('improve.btnInspectWorkflowDraft')}</button>
            </div>
          ` : ''}
        </div>

        ${renderAlreadyInstalledNotice(previewObj)}
        ${renderProviderTrustNotice(previewObj, isApplied)}

        ${previewObj.description || previewObj.issue || previewObj.reason ? `
          <div class="card" style="padding: 10px 12px;">
            <div style="font-size: 11px; font-weight: 600; color: var(--text-secondary); margin-bottom: 4px;" data-i18n="improve.reasonTitle">${t('improve.reasonTitle')}</div>
            <div style="font-size: 12px; line-height: 1.5; color: var(--text-main);">${escapeHtml(previewObj.description || previewObj.issue || previewObj.reason)}</div>
          </div>
        ` : ''}

        ${evidenceList.length > 0 ? `
          <div>
            <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;" data-i18n="improve.evidenceHeading" data-i18n-params="${escapeHtml(JSON.stringify({ count: evidenceList.length }))}">${t('improve.evidenceHeading', { count: evidenceList.length })}</h3>
            <div style="display: flex; flex-direction: column; gap: 6px;">
              ${evidenceList.map(ev => {
                const locateTooltip = t('improve.locateSourceTooltip', {
                  sessionId: ev.sessionId || '-',
                  messageId: ev.messageId || '-'
                });
                return `
                  <div class="card" style="padding: 10px 12px; margin-bottom: 0;">
                    ${ev.quote ? `<div style="font-size: 12px; margin-bottom: 6px; color: var(--text-main); font-style: italic; line-height: 1.45;">"${escapeHtml(ev.quote)}"</div>` : ''}
                    <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; font-size: 11px; color: var(--text-secondary);">
                      <div style="display: flex; align-items: center; gap: 8px;">
                        ${ev.task ? `<span><span data-i18n="improve.evidenceTaskLabel">${t('improve.evidenceTaskLabel')}</span>: ${escapeHtml(ev.task)}</span>` : ''}
                        ${ev.timestamp ? `<span><span data-i18n="improve.evidenceTimeLabel">${t('improve.evidenceTimeLabel')}</span>: ${formatTime(ev.timestamp)}</span>` : ''}
                      </div>
                      ${ev.sessionId ? `
                        <button type="button" class="btn-open-source" data-session-id="${escapeHtml(ev.sessionId)}" ${ev.messageId ? `data-message-id="${escapeHtml(ev.messageId)}"` : ''} title="${escapeHtml(locateTooltip)}">
                          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg>
                          <span data-i18n="improve.locateSourceMsg">${t('improve.locateSourceMsg')}</span>
                        </button>
                      ` : ''}
                    </div>
                    <details style="margin-top: 6px; font-size: 10px; color: var(--text-muted);">
                      <summary style="cursor: pointer;" data-i18n="improve.techIdSummary">${t('improve.techIdSummary')}</summary>
                      <div class="font-mono" style="margin-top: 2px;">
                        <div><span data-i18n="improve.sessionIdLabel">${t('improve.sessionIdLabel')}</span>: ${escapeHtml(ev.sessionId || '-')}</div>
                        ${ev.messageId ? `<div><span data-i18n="improve.messageIdLabel">${t('improve.messageIdLabel')}</span>: ${escapeHtml(ev.messageId)}</div>` : ''}
                      </div>
                    </details>
                  </div>
                `;
              }).join('')}
            </div>
          </div>
        ` : ''}

        <div>
          <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;" data-i18n="improve.diffHeading" data-i18n-params="${escapeHtml(JSON.stringify({ count: previewList.length }))}">${t('improve.diffHeading', { count: previewList.length })}</h3>
          <div style="display: flex; flex-direction: column; gap: 10px;">
            ${previewList.map(item => `
              <div class="card" style="margin-bottom: 0; padding: 10px 12px;">
                <div style="font-size: 11px; font-family: var(--font-mono); font-weight: 600; margin-bottom: 6px;">
                  ${escapeHtml(item.path || t('improve.targetFile'))}
                  ${item.delete ? `<span class="status-badge status-red" style="margin-left: 6px;" data-i18n="improve.badgeDelete">${t('improve.badgeDelete')}</span>` : ''}
                </div>
                ${renderDiffView(item.before || '', item.content || item.after || '')}
              </div>
            `).join('')}
          </div>
        </div>

        <details class="card" style="margin-top: 10px; padding: 10px 12px;">
          <summary style="font-size: 11px; cursor: pointer; color: var(--text-muted); user-select: none;" data-i18n="improve.rawJsonSummary">${t('improve.rawJsonSummary')}</summary>
          <div class="code-view font-mono" style="margin-top: 8px; font-size: 11px; max-height: 200px; overflow: auto;">${escapeHtml(JSON.stringify(previewList, null, 2))}</div>
        </details>
      `;

      const inspectWfBtn = document.getElementById('btn-drawer-inspect-wf');
      if (inspectWfBtn && previewObj.workflowDraft) {
        inspectWfBtn.addEventListener('click', () => {
          openEditWorkflowModal(previewObj.workflowDraft);
        });
      }
    } catch (err) {
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== improvePreviewSequence || thisDrawer !== currentDrawerInstance || state.selectedSuggestionId !== suggestionId || !isDrawerOpen || state.currentProject !== thisProject || state.currentPage !== thisPage) {
        return;
      }
      setDrawerTitle({ key: 'common.loadFailed' }, { key: 'common.error' });
      const drawerContent = document.getElementById('drawer-content');
      if (drawerContent) {
        if (err && err.i18nKey) {
          drawerContent.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="improve.loadPreviewFailedPrefix">${escapeHtml(t('improve.loadPreviewFailedPrefix'))}</span><span data-i18n="${err.i18nKey}">${escapeHtml(t(err.i18nKey))}</span>
            </div>
          `;
        } else {
          drawerContent.innerHTML = `
            <div class="alert-banner alert-danger">
              <span data-i18n="improve.loadPreviewFailedPrefix">${escapeHtml(t('improve.loadPreviewFailedPrefix'))}</span><span>${escapeHtml(err ? err.message : String(err))}</span>
            </div>
          `;
        }
      }
    }
  }

  function renderDiffView(beforeText, afterText) {
    const beforeLines = (beforeText || '').split('\n');
    const afterLines = (afterText || '').split('\n');

    let lines = [];
    if (!beforeText && afterText) {
      lines = afterLines.map(l => ({ type: 'addition', marker: '+', text: l }));
    } else {
      beforeLines.forEach(l => lines.push({ type: 'deletion', marker: '-', text: l }));
      afterLines.forEach(l => lines.push({ type: 'addition', marker: '+', text: l }));
    }

    return `
      <div class="diff-container">
        ${lines.map(l => `
          <div class="diff-line ${l.type}">
            <span class="diff-marker">${l.marker}</span>
            <span>${escapeHtml(l.text)}</span>
          </div>
        `).join('')}
      </div>
    `;
  }

  function openConfirmApplyModal(previewObj) {
    if (!previewObj || isAlreadyInstalledHook(previewObj)) {
      showToast({ key: 'improve.alreadyInstalledNoop' }, 'info');
      return;
    }
    const previewList = previewObj.preview || previewObj.operations || [];
    const carrierName = previewObj.carrier || t('improve.defaultCarrier');
    const modalBody = `
      <div class="alert-banner alert-warning">
        <span data-i18n="improve.confirmApplyWarning">${t('improve.confirmApplyWarning')}</span>
      </div>
      ${renderProviderTrustNotice(previewObj, false)}
      <p style="font-size: 12px; color: var(--text-main); margin-top: 8px;">
        <span data-i18n="improve.confirmApplyWillWrite">${t('improve.confirmApplyWillWrite')}</span> <strong>${escapeHtml(carrierName)}</strong>：
      </p>
      <ul style="padding-left: 18px; font-size: 11px; color: var(--text-secondary); margin-top: 6px;">
        ${previewList.map(op => `<li><code class="code-badge">${escapeHtml(op.path || '')}</code></li>`).join('')}
      </ul>
    `;

    openModal({ key: 'improve.confirmApplyModalTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-apply" data-i18n="common.cancel">${escapeHtml(t('common.cancel'))}</button>
      <button class="btn btn-primary" id="btn-confirm-apply" data-i18n="improve.btnConfirmApplyAction">${escapeHtml(t('improve.btnConfirmApplyAction'))}</button>
    `);

    document.getElementById('btn-cancel-apply').addEventListener('click', closeModal);
    const btnConfirm = document.getElementById('btn-confirm-apply');
    if (btnConfirm) {
      btnConfirm.addEventListener('click', async () => {
        if (isAlreadyInstalledHook(previewObj)) {
          showToast({ key: 'improve.alreadyInstalledNoop' }, 'info');
          closeModal();
          return;
        }
        if (btnConfirm.disabled) return;
        btnConfirm.disabled = true;
        setElementDescriptor(btnConfirm, { key: 'improve.btnApplying' });

        const thisModal = currentModalInstance;
        const thisPage = state.currentPage;
        const thisProject = state.currentProject;

        try {
          await callBridge('improve.apply', { id: previewObj.id });

          const modal = document.getElementById('modal-container');
          const isModalOpen = modal && !modal.classList.contains('hidden');
          if (thisModal !== currentModalInstance || !isModalOpen || !document.contains(modal) || state.currentPage !== thisPage || state.currentProject !== thisProject) {
            return;
          }

          showToast({ key: 'improve.applySuccess' });
          closeModal();
          closeDrawer();
          await refreshDashboard(true, true);
        } catch (err) {
          const modal = document.getElementById('modal-container');
          const isModalOpen = modal && !modal.classList.contains('hidden');
          if (thisModal !== currentModalInstance || !isModalOpen || !document.contains(modal) || state.currentPage !== thisPage || state.currentProject !== thisProject) {
            return;
          }
          btnConfirm.disabled = false;
          setElementDescriptor(btnConfirm, { key: 'improve.btnConfirmApplyAction' });
          showToast({ key: 'improve.applyFailed', params: { error: err.message } }, 'error');
        }
      });
    }
  }

  // -------------------------------------------------------------------------
  // 6. LAB VIEW (Real backend schemas: results grouped by variant, summary, regression tab)
  // -------------------------------------------------------------------------
  function renderLabView(container) {
    const evals = (state.dashboard && state.dashboard.evals) || [];

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="lab.header.title">${escapeHtml(t('lab.header.title'))}</h1>
          <p data-i18n="lab.header.desc">${escapeHtml(t('lab.header.desc'))}</p>
        </div>
        <div class="page-actions">
          <button id="btn-new-lab" class="btn btn-primary btn-sm" data-i18n="lab.actions.newLab">${escapeHtml(t('lab.actions.newLab'))}</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.labActiveTab === 'evals' ? 'active' : ''}" data-labtab="evals" data-i18n="lab.tabs.evalsWithCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: evals.length }))}">${escapeHtml(t('lab.tabs.evalsWithCount', { count: evals.length }))}</button>
        <button class="tab-btn ${state.labActiveTab === 'regression' ? 'active' : ''}" data-labtab="regression" data-i18n="lab.tabs.regression">${escapeHtml(t('lab.tabs.regression'))}</button>
      </div>

      <div id="lab-tab-content"></div>
    `;

    container.querySelectorAll('[data-labtab]').forEach(tab => {
      tab.addEventListener('click', () => {
        state.labActiveTab = tab.getAttribute('data-labtab');
        container.querySelectorAll('[data-labtab]').forEach(t => t.classList.remove('active'));
        tab.classList.add('active');
        renderLabTabContent();
      });
    });

    document.getElementById('btn-new-lab').addEventListener('click', openCreateLabModal);
    renderLabTabContent();
  }

  function formatFinitePassRate(rate, isPending = false) {
    if (isPending) return tHtml('lab.metric.notRun');
    if (rate === null || rate === undefined || typeof rate !== 'number' || isNaN(rate)) return tHtml('lab.metric.notProvided');
    return (rate * 100).toFixed(0) + '%';
  }

  function formatFiniteDuration(ms, isPending = false) {
    if (isPending) return tHtml('lab.metric.notRun');
    if (ms === null || ms === undefined || typeof ms !== 'number' || isNaN(ms)) return tHtml('lab.metric.notProvided');
    return Math.round(ms) + 'ms';
  }

  function formatFiniteTokens(tok, isPending = false) {
    if (isPending) return tHtml('lab.metric.notRun');
    if (tok === null || tok === undefined || typeof tok !== 'number' || isNaN(tok)) return tHtml('lab.metric.notProvided');
    return Math.round(tok).toLocaleString() + ' tok';
  }

  function formatFiniteCount(n, isPending = false) {
    if (isPending) return tHtml('lab.metric.notRun');
    if (n === null || n === undefined || typeof n !== 'number' || isNaN(n)) return tHtml('lab.metric.notProvided');
    return String(n);
  }

  function getEvalDecisionBadge(decision, state) {
    const st = (state || '').toLowerCase();
    if (st === 'running') {
      return `<span class="status-badge status-blue" data-i18n="lab.decisionBadge.running" data-i18n-title="lab.decisionBadge.runningTitle" title="${escapeHtml(t('lab.decisionBadge.runningTitle'))}">${escapeHtml(t('lab.decisionBadge.running'))}</span>`;
    }
    if (st === 'pending_approval' || st === 'pending approval') {
      return `<span class="status-badge status-neutral" data-i18n="lab.decisionBadge.pendingApproval" data-i18n-title="lab.decisionBadge.pendingApprovalTitle" title="${escapeHtml(t('lab.decisionBadge.pendingApprovalTitle'))}">${escapeHtml(t('lab.decisionBadge.pendingApproval'))}</span>`;
    }
    const d = (decision || '').toLowerCase();
    switch (d) {
      case 'ready_for_review':
        return `<span class="status-badge status-sage" data-i18n="lab.decisionBadge.readyForReview" data-i18n-title="lab.decisionBadge.readyForReviewTitle" title="${escapeHtml(t('lab.decisionBadge.readyForReviewTitle'))}">${escapeHtml(t('lab.decisionBadge.readyForReview'))}</span>`;
      case 'inconclusive':
        return `<span class="status-badge status-amber" data-i18n="lab.decisionBadge.inconclusive" data-i18n-title="lab.decisionBadge.inconclusiveTitle" title="${escapeHtml(t('lab.decisionBadge.inconclusiveTitle'))}">${escapeHtml(t('lab.decisionBadge.inconclusive'))}</span>`;
      case 'reject':
        return `<span class="status-badge status-red" data-i18n="lab.decisionBadge.reject" data-i18n-title="lab.decisionBadge.rejectTitle" title="${escapeHtml(t('lab.decisionBadge.rejectTitle'))}">${escapeHtml(t('lab.decisionBadge.reject'))}</span>`;
      default:
        return '<span class="status-badge status-neutral">-</span>';
    }
  }

  function getEvalDecisionTitle(decision) {
    switch ((decision || '').toLowerCase()) {
      case 'ready_for_review':
        return t('lab.decisionTitle.readyForReview');
      case 'inconclusive':
        return t('lab.decisionTitle.inconclusive');
      case 'reject':
        return t('lab.decisionTitle.reject');
      default:
        return decision ? t('lab.decisionTitle.fallback', { decision }) : t('lab.decisionTitle.notGenerated');
    }
  }

  function getEvalDecisionTitleNode(decision) {
    const d = (decision || '').toLowerCase();
    switch (d) {
      case 'ready_for_review':
        return `<strong data-i18n="lab.decisionTitle.readyForReview">${escapeHtml(t('lab.decisionTitle.readyForReview'))}</strong>`;
      case 'inconclusive':
        return `<strong data-i18n="lab.decisionTitle.inconclusive">${escapeHtml(t('lab.decisionTitle.inconclusive'))}</strong>`;
      case 'reject':
        return `<strong data-i18n="lab.decisionTitle.reject">${escapeHtml(t('lab.decisionTitle.reject'))}</strong>`;
      default:
        if (decision) {
          return `<strong data-i18n="lab.decisionTitle.fallback" data-i18n-params="${escapeHtml(JSON.stringify({ decision }))}">${escapeHtml(t('lab.decisionTitle.fallback', { decision }))}</strong>`;
        }
        return `<strong data-i18n="lab.decisionTitle.notGenerated">${escapeHtml(t('lab.decisionTitle.notGenerated'))}</strong>`;
    }
  }

  function getEvalDecisionExplanation(decision) {
    switch ((decision || '').toLowerCase()) {
      case 'ready_for_review':
        return t('lab.decisionExplanation.readyForReview');
      case 'inconclusive':
        return t('lab.decisionExplanation.inconclusive');
      case 'reject':
        return t('lab.decisionExplanation.reject');
      default:
        return t('lab.decisionExplanation.default');
    }
  }

  function getEvalDecisionExplanationKey(decision) {
    switch ((decision || '').toLowerCase()) {
      case 'ready_for_review':
        return 'lab.decisionExplanation.readyForReview';
      case 'inconclusive':
        return 'lab.decisionExplanation.inconclusive';
      case 'reject':
        return 'lab.decisionExplanation.reject';
      default:
        return 'lab.decisionExplanation.default';
    }
  }

  function formatVariantSummary(variant) {
    if (!variant) return `<span class="text-muted" data-i18n="lab.variant.defaultConfig">${escapeHtml(t('lab.variant.defaultConfig'))}</span>`;
    const parts = [];
    const files = variant.files || [];
    const memories = variant.memories || [];
    if (memories.length > 0) {
      const memList = memories.map(m => m.title || m.id).join(', ');
      parts.push(`<span data-i18n="lab.variant.memorySummary" data-i18n-params="${escapeHtml(JSON.stringify({ count: memories.length, list: memList }))}">${escapeHtml(t('lab.variant.memorySummary', { count: memories.length, list: memList }))}</span>`);
    }
    if (files.length > 0) {
      const fileList = files.map(f => f.path).join(', ');
      parts.push(`<span data-i18n="lab.variant.fileSummary" data-i18n-params="${escapeHtml(JSON.stringify({ count: files.length, list: fileList }))}">${escapeHtml(t('lab.variant.fileSummary', { count: files.length, list: fileList }))}</span>`);
    }
    const memoryContext = memories.map(m => `${m.title || ''}\n${m.content || ''}`).join('\n\n');
    if (variant.context && (!memories.length || variant.context !== memoryContext)) {
      const charCount = variant.context.length;
      parts.push(`<span data-i18n="lab.variant.customContext" data-i18n-params="${escapeHtml(JSON.stringify({ count: charCount }))}">${escapeHtml(t('lab.variant.customContext', { count: charCount }))}</span>`);
    }
    return parts.length > 0 ? parts.join(' · ') : `<span class="text-muted" data-i18n="lab.variant.noAdditions">${escapeHtml(t('lab.variant.noAdditions'))}</span>`;
  }

  function findVelaSessionBySourceId(sourceSessionId, expectedProject = null) {
    if (!sourceSessionId) return null;
    const sessions = (state.dashboard && state.dashboard.sessions) || [];
    return sessions.find(s => {
      const isCodex = (s.provider || '').toLowerCase() === 'codex';
      if (!isCodex) return false;
      if (expectedProject) {
        const sProj = s.project || s.path || '';
        if (sProj !== expectedProject) return false;
      }
      return s.sourceSessionId === sourceSessionId || s.id === sourceSessionId;
    }) || null;
  }

  function resolveMemoryInfo(memId) {
    const memories = (state.dashboard && state.dashboard.memories) || [];
    const found = memories.find(m => m.id === memId);
    return {
      id: memId,
      title: found ? (found.title || found.id) : memId,
      content: found ? found.content : '',
      found: !!found
    };
  }

  function renderLabTabContent() {
    const target = document.getElementById('lab-tab-content');
    if (!target) return;

    if (state.labActiveTab === 'regression') {
      renderLabRegressionSection(target);
      return;
    }

    const evals = (state.dashboard && state.dashboard.evals) || [];

    target.innerHTML = `
      <div class="card" style="background: var(--bg-subtle); margin-bottom: 14px;">
        <div style="font-size: 12px; line-height: 1.5; color: var(--text-secondary);">
          <strong data-i18n="lab.principles.title">${escapeHtml(t('lab.principles.title'))}</strong>
          <span data-i18n="lab.principles.body">${escapeHtml(t('lab.principles.body'))}</span>
        </div>
      </div>

      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th data-i18n="lab.table.name">${escapeHtml(t('lab.table.name'))}</th>
              <th data-i18n="lab.table.evaluator">${escapeHtml(t('lab.table.evaluator'))}</th>
              <th data-i18n="lab.table.category">${escapeHtml(t('lab.table.category'))}</th>
              <th data-i18n="lab.table.state">${escapeHtml(t('lab.table.state'))}</th>
              <th data-i18n="lab.table.decision">${escapeHtml(t('lab.table.decision'))}</th>
              <th data-i18n="lab.table.baselineCol">${escapeHtml(t('lab.table.baselineCol'))}</th>
              <th data-i18n="lab.table.candidateCol">${escapeHtml(t('lab.table.candidateCol'))}</th>
              <th style="text-align: right; width: 100px;" data-i18n="lab.table.actions">${escapeHtml(t('lab.table.actions'))}</th>
            </tr>
          </thead>
          <tbody>
            ${evals.length === 0 ? `<tr><td colspan="8" style="text-align: center; color: var(--text-muted); padding: 32px;" data-i18n="lab.table.empty">${escapeHtml(t('lab.table.empty'))}</td></tr>` : ''}
            ${evals.map(ev => {
              const st = (ev.state || 'pending_approval').toLowerCase();
              const isPending = (st === 'pending_approval' || st === 'pending approval');
              const baseSummary = ev.summary && ev.summary.baseline;
              const candSummary = ev.summary && ev.summary.candidate;

              let baseHtml = '';
              if (isPending) {
                baseHtml = tHtml('lab.metric.notRun');
              } else {
                const bRate = formatFinitePassRate(baseSummary ? baseSummary.passRate : null);
                const bDur = formatFiniteDuration(baseSummary ? baseSummary.averageDurationMs : null);
                const parts = [bRate, bDur];
                if (baseSummary && baseSummary.averageTokens !== null && baseSummary.averageTokens !== undefined) {
                  parts.push(formatFiniteTokens(baseSummary.averageTokens));
                }
                baseHtml = parts.join(' · ');
              }

              let candHtml = '';
              if (isPending) {
                candHtml = tHtml('lab.metric.notRun');
              } else {
                const cRate = formatFinitePassRate(candSummary ? candSummary.passRate : null);
                const cDur = formatFiniteDuration(candSummary ? candSummary.averageDurationMs : null);
                const parts = [cRate, cDur];
                if (candSummary && candSummary.averageTokens !== null && candSummary.averageTokens !== undefined) {
                  parts.push(formatFiniteTokens(candSummary.averageTokens));
                }
                candHtml = parts.join(' · ');
              }

              const isAgent = (ev.evaluator === 'codex_agent');
              const evaluatorBadge = isAgent
                ? `<span class="code-badge" data-i18n="lab.evaluator.codexAgent">${escapeHtml(t('lab.evaluator.codexAgent'))}</span>`
                : `<span class="code-badge" data-i18n="lab.evaluator.deterministicCmd">${escapeHtml(t('lab.evaluator.deterministicCmd'))}</span>`;
              const decisionBadge = getEvalDecisionBadge(ev.summary && ev.summary.decision, ev.state);

              return `
                <tr class="clickable-row" data-id="${escapeHtml(ev.id)}">
                  <td><strong>${escapeHtml(ev.title || '-')}</strong></td>
                  <td>${evaluatorBadge}</td>
                  <td><span class="code-badge">${escapeHtml(ev.evaluationKind || ev.kind || 'context')}</span></td>
                  <td>${getEvalStateBadge(st)}</td>
                  <td>${decisionBadge}</td>
                  <td><span class="font-mono" style="font-size: 11px;">${baseHtml}</span></td>
                  <td><span class="font-mono" style="font-size: 11px;">${candHtml}</span></td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-lab-compare" data-id="${escapeHtml(ev.id)}" data-i18n="lab.actions.compareDetails">${escapeHtml(t('lab.actions.compareDetails'))}</button>
                  </td>
                </tr>
              `;
            }).join('')}
          </tbody>
        </table>
      </div>
    `;

    target.querySelectorAll('.btn-lab-compare').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        openLabCompareDrawer(btn.getAttribute('data-id'));
      });
    });

    target.querySelectorAll('tr.clickable-row').forEach(row => {
      row.addEventListener('click', () => {
        openLabCompareDrawer(row.getAttribute('data-id'));
      });
    });
  }

  async function renderLabRegressionSection(target) {
    const thisGen = renderGeneration;
    const thisPage = state.currentPage;
    const thisScope = state.currentProject;

    target.innerHTML = `<div class="text-secondary" style="font-size: 12px; padding: 20px 0;" data-i18n="lab.regression.loading">${escapeHtml(t('lab.regression.loading'))}</div>`;

    try {
      const reg = await callBridge('regression.list', state.currentProject ? { project: state.currentProject } : {});
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(target)) return;
      const comparisons = (reg && reg.workflowComparisons) || [];
      const evaluations = (reg && reg.evaluations) || [];

      const formatPerSide = (side) => {
        if (!side) return tHtml('lab.metric.notProvided');
        const runsHtml = tHtml('lab.regression.runsCount', { count: side.runs ?? 0 });
        const successRateText = (side.successRate !== null && side.successRate !== undefined && !isNaN(side.successRate))
          ? `${(side.successRate * 100).toFixed(1)}%`
          : null;
        const meanRuntimeText = (side.meanRuntimeMs !== null && side.meanRuntimeMs !== undefined && !isNaN(side.meanRuntimeMs))
          ? `${Math.round(side.meanRuntimeMs)}ms`
          : null;
        const rateHtml = successRateText !== null ? escapeHtml(successRateText) : tHtml('lab.metric.notProvided');
        const durHtml = meanRuntimeText !== null ? escapeHtml(meanRuntimeText) : tHtml('lab.metric.notProvided');
        return `${runsHtml} · ${tHtml('lab.regression.passRateLabel')} ${rateHtml} · ${tHtml('lab.regression.meanDurationLabel')} ${durHtml}`;
      };

      target.innerHTML = `
        <div class="card" style="margin-bottom: 14px;">
          <div class="card-header">
            <span class="card-title" data-i18n="lab.regression.workflowTitle">${escapeHtml(t('lab.regression.workflowTitle'))}</span>
            <span class="status-badge status-neutral" data-i18n="lab.regression.envDisclaimer">${escapeHtml(t('lab.regression.envDisclaimer'))}</span>
          </div>
          ${comparisons.length === 0 ? `<div style="font-size: 12px; color: var(--text-muted); padding: 8px 0;" data-i18n="lab.regression.emptyWorkflows">${escapeHtml(t('lab.regression.emptyWorkflows'))}</div>` : `
            <div class="table-wrapper" style="margin-bottom: 0;">
              <table class="data-table">
                <thead>
                  <tr>
                    <th data-i18n="lab.regression.thWorkflowId">${escapeHtml(t('lab.regression.thWorkflowId'))}</th>
                    <th data-i18n="lab.regression.thVersions">${escapeHtml(t('lab.regression.thVersions'))}</th>
                    <th data-i18n="lab.regression.thBaselinePerf">${escapeHtml(t('lab.regression.thBaselinePerf'))}</th>
                    <th data-i18n="lab.regression.thCandidatePerf">${escapeHtml(t('lab.regression.thCandidatePerf'))}</th>
                    <th data-i18n="lab.regression.thCausality">${escapeHtml(t('lab.regression.thCausality'))}</th>
                  </tr>
                </thead>
                <tbody>
                  ${comparisons.map(c => `
                    <tr>
                      <td><strong>${escapeHtml(c.workflowId || '-')}</strong></td>
                      <td><span class="code-badge">v${escapeHtml(String(c.baselineVersion ?? '-'))} vs v${escapeHtml(String(c.candidateVersion ?? '-'))}</span></td>
                      <td style="font-size: 11px;">${formatPerSide(c.baseline)}</td>
                      <td style="font-size: 11px;">${formatPerSide(c.candidate)}</td>
                      <td style="font-size: 11px; color: var(--text-muted);" data-i18n="lab.regression.causalityWarning">${escapeHtml(t('lab.regression.causalityWarning'))}</td>
                    </tr>
                  `).join('')}
                </tbody>
              </table>
            </div>
          `}
        </div>

        <div class="card">
          <div class="card-header">
            <span class="card-title" data-i18n="lab.regression.evalsTitle">${escapeHtml(t('lab.regression.evalsTitle'))}</span>
            <span class="text-secondary" style="font-size: 11px;" data-i18n="lab.regression.evalsSubtitle">${escapeHtml(t('lab.regression.evalsSubtitle'))}</span>
          </div>
          ${evaluations.length === 0 ? `<div style="font-size: 12px; color: var(--text-muted); padding: 8px 0;" data-i18n="lab.regression.emptyEvals">${escapeHtml(t('lab.regression.emptyEvals'))}</div>` : `
            <div class="table-wrapper" style="margin-bottom: 0;">
              <table class="data-table">
                <thead>
                  <tr>
                    <th data-i18n="lab.regression.thEvalId">${escapeHtml(t('lab.regression.thEvalId'))}</th>
                    <th data-i18n="lab.regression.thTitle">${escapeHtml(t('lab.regression.thTitle'))}</th>
                    <th data-i18n="lab.regression.thKind">${escapeHtml(t('lab.regression.thKind'))}</th>
                    <th data-i18n="lab.regression.thState">${escapeHtml(t('lab.regression.thState'))}</th>
                    <th data-i18n="lab.regression.thRuntimeDelta">${escapeHtml(t('lab.regression.thRuntimeDelta'))}</th>
                    <th data-i18n="lab.regression.thSuccessDelta">${escapeHtml(t('lab.regression.thSuccessDelta'))}</th>
                    <th style="text-align: right; width: 90px;" data-i18n="lab.regression.thActions">${escapeHtml(t('lab.regression.thActions'))}</th>
                  </tr>
                </thead>
                <tbody>
                  ${evaluations.map(e => {
                    const sm = e.summary || {};
                    const runtimeDelta = (sm.runtimeDeltaMs !== undefined && sm.runtimeDeltaMs !== null && !isNaN(sm.runtimeDeltaMs))
                      ? `${sm.runtimeDeltaMs > 0 ? '+' : ''}${Math.round(sm.runtimeDeltaMs)}ms`
                      : null;
                    const successDelta = (sm.successDelta !== undefined && sm.successDelta !== null && !isNaN(sm.successDelta))
                      ? `${sm.successDelta > 0 ? '+' : ''}${(sm.successDelta * 100).toFixed(1)}%`
                      : null;
                    const runtimeHtml = runtimeDelta !== null ? escapeHtml(runtimeDelta) : tHtml('lab.metric.notProvided');
                    const successHtml = successDelta !== null ? escapeHtml(successDelta) : tHtml('lab.metric.notProvided');
                    return `
                      <tr class="clickable-row btn-eval-row" data-id="${escapeHtml(e.id)}">
                        <td><span class="code-badge">${escapeHtml(e.id ? e.id.substring(0, 8) : '-')}</span></td>
                        <td><strong>${escapeHtml(e.title || '-')}</strong></td>
                        <td><span class="code-badge">${escapeHtml(e.evaluationKind || e.kind || 'context')}</span></td>
                        <td>${getEvalStateBadge(e.state)}</td>
                        <td class="font-mono">${runtimeHtml}</td>
                        <td class="font-mono">${successHtml}</td>
                        <td style="text-align: right;">
                          <button class="btn btn-secondary btn-sm btn-open-eval-compare" data-id="${escapeHtml(e.id)}" data-i18n="lab.actions.compareDetails">${escapeHtml(t('lab.actions.compareDetails'))}</button>
                        </td>
                      </tr>
                    `;
                  }).join('')}
                </tbody>
              </table>
            </div>
          `}
        </div>
      `;

      target.querySelectorAll('.btn-open-eval-compare').forEach(btn => {
        btn.addEventListener('click', (ev) => {
          ev.stopPropagation();
          openLabCompareDrawer(btn.getAttribute('data-id'));
        });
      });

      target.querySelectorAll('tr.btn-eval-row').forEach(row => {
        row.addEventListener('click', () => {
          openLabCompareDrawer(row.getAttribute('data-id'));
        });
      });
    } catch (err) {
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(target)) return;
      target.innerHTML = `<div class="alert-banner alert-danger"><span data-i18n="lab.regression.fetchErrorPrefix">${escapeHtml(t('lab.regression.fetchErrorPrefix'))}</span>: ${escapeHtml(err.message)}</div>`;
    }
  }

  function getEvalStateBadge(st) {
    const s = (st || '').toLowerCase();
    switch (s) {
      case 'completed':
        return `<span class="status-badge status-sage" data-i18n="lab.state.completed">${escapeHtml(t('lab.state.completed'))}</span>`;
      case 'pending_approval':
      case 'pending approval':
        return `<span class="status-badge status-amber" data-i18n="lab.state.pendingApproval">${escapeHtml(t('lab.state.pendingApproval'))}</span>`;
      case 'running':
        return `<span class="status-badge status-amber" data-i18n="lab.state.running">${escapeHtml(t('lab.state.running'))}</span>`;
      case 'failed':
        return `<span class="status-badge status-red" data-i18n="lab.state.failed">${escapeHtml(t('lab.state.failed'))}</span>`;
      case 'rejected':
        return `<span class="status-badge status-neutral" data-i18n="lab.state.rejected">${escapeHtml(t('lab.state.rejected'))}</span>`;
      default:
        if (st) {
          return `<span class="status-badge status-neutral">${escapeHtml(st)}</span>`;
        }
        return `<span class="status-badge status-neutral" data-i18n="lab.state.ready">${escapeHtml(t('lab.state.ready'))}</span>`;
    }
  }

  function openCreateLabModal(initialConfig = {}) {
    const defaultBaseline = JSON.stringify(initialConfig.baseline || {}, null, 2);

    let defaultCandidateObj = initialConfig.candidate || {};
    if (!initialConfig.candidate) {
      if (initialConfig.candidateFiles && initialConfig.candidateFiles.length > 0) {
        defaultCandidateObj.files = initialConfig.candidateFiles;
      }
      if (initialConfig.candidateMemoryIds && initialConfig.candidateMemoryIds.length > 0) {
        defaultCandidateObj.memoryIds = initialConfig.candidateMemoryIds;
      }
    }
    const defaultCandidate = JSON.stringify(defaultCandidateObj, null, 2);

    const candidateProject = (initialConfig.project || state.currentProject || '').trim();
    const matchedProject = (state.registeredProjects || []).find(p => (p.path && p.path === candidateProject) || (p.id && p.id === candidateProject));
    const selectedProject = matchedProject ? (matchedProject.path || matchedProject.id) : '';

    let currentMode = initialConfig.mode || (initialConfig.sourceSuggestionId ? 'codex_agent' : 'codex_agent');

    const defaultCommand = JSON.stringify(initialConfig.command || ["npm", "test"], null, 2);
    const defaultVerifyCommand = initialConfig.verificationCommand ? JSON.stringify(initialConfig.verificationCommand, null, 2) : '';

    const sourceSugId = initialConfig.sourceSuggestionId || '';
    const candidateMemIds = initialConfig.candidateMemoryIds || (defaultCandidateObj.memoryIds || []);
    const candidateFileList = initialConfig.candidateFiles || (defaultCandidateObj.files || []);
    const candidateExplanation = initialConfig.candidateExplanation || '';

    const modalBody = `
      <div class="mode-switch" role="tablist" aria-label="${escapeHtml(t('lab.create.modeSwitchAria'))}" data-i18n-aria-label="lab.create.modeSwitchAria">
        <button type="button" role="tab" id="tab-mode-agent" aria-selected="${currentMode === 'codex_agent' ? 'true' : 'false'}" aria-controls="lab-section-agent" class="mode-switch-btn ${currentMode === 'codex_agent' ? 'active' : ''}" data-target-mode="codex_agent" data-i18n="lab.create.modeAgent">${escapeHtml(t('lab.create.modeAgent'))}</button>
        <button type="button" role="tab" id="tab-mode-cmd" aria-selected="${currentMode === 'command' ? 'true' : 'false'}" aria-controls="lab-section-cmd" class="mode-switch-btn ${currentMode === 'command' ? 'active' : ''}" data-target-mode="command" data-i18n="lab.create.modeCmd">${escapeHtml(t('lab.create.modeCmd'))}</button>
      </div>

      <!-- Agent Mode Form -->
      <div id="lab-section-agent" class="${currentMode === 'codex_agent' ? '' : 'hidden'}">
        ${sourceSugId ? `
          <div class="card" style="background: var(--bg-subtle); padding: 8px 10px; margin-bottom: 12px; font-size: 11px;">
            <span class="text-secondary" data-i18n="lab.create.linkedSuggestion">${escapeHtml(t('lab.create.linkedSuggestion'))}</span>:
            <span class="font-mono"><strong>${escapeHtml(sourceSugId)}</strong></span>
            <input type="hidden" id="lab-agent-source-sug" value="${escapeHtml(sourceSugId)}">
          </div>
        ` : ''}

        <div class="form-group" style="margin-bottom: 12px;">
          <label for="lab-agent-title" class="form-label" data-i18n="lab.create.titleLabel">${escapeHtml(t('lab.create.titleLabel'))}</label>
          <input type="text" id="lab-agent-title" class="form-input" placeholder="${escapeHtml(t('lab.create.titlePlaceholder'))}" data-i18n-placeholder="lab.create.titlePlaceholder" value="${escapeHtml(initialConfig.title || (sourceSugId ? '调优建议验证实验' : 'Codex Agent 对照评测'))}">
        </div>

        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 12px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-agent-project" class="form-label" data-i18n="lab.create.projectLabel">${escapeHtml(t('lab.create.projectLabel'))}</label>
            <select id="lab-agent-project" class="form-select">
              <option value="" ${!selectedProject ? 'selected' : ''} data-i18n="lab.create.selectProject">${escapeHtml(t('lab.create.selectProject'))}</option>
              ${(state.registeredProjects || []).map(p => {
                const val = p.path || p.id;
                return `<option value="${escapeHtml(val)}" ${selectedProject === val ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>`;
              }).join('')}
            </select>
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-agent-kind" class="form-label" data-i18n="lab.create.kindLabel">${escapeHtml(t('lab.create.kindLabel'))}</label>
            <select id="lab-agent-kind" class="form-select">
              <option value="memory" ${initialConfig.kind === 'memory' || (!initialConfig.kind && candidateMemIds.length > 0) ? 'selected' : ''} data-i18n="lab.create.kindMemoryOption">${escapeHtml(t('lab.create.kindMemoryOption'))}</option>
              <option value="context" ${initialConfig.kind === 'context' || (!initialConfig.kind && candidateMemIds.length === 0) ? 'selected' : ''} data-i18n="lab.create.kindContextOption">${escapeHtml(t('lab.create.kindContextOption'))}</option>
              <option value="workflow" ${initialConfig.kind === 'workflow' ? 'selected' : ''} data-i18n="lab.create.kindWorkflowOption">${escapeHtml(t('lab.create.kindWorkflowOption'))}</option>
            </select>
          </div>
        </div>

        <div style="display: grid; grid-template-columns: 2fr 1fr; gap: 12px; margin-bottom: 12px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-agent-model" class="form-label" data-i18n="lab.create.modelLabel">${escapeHtml(t('lab.create.modelLabel'))}</label>
            <div id="help-agent-model" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.modelHelp">${escapeHtml(t('lab.create.modelHelp'))}</div>
            <input type="text" id="lab-agent-model" class="form-input font-mono" placeholder="${escapeHtml(t('lab.create.modelPlaceholder'))}" data-i18n-placeholder="lab.create.modelPlaceholder" value="${escapeHtml(initialConfig.model || '')}" aria-describedby="help-agent-model">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-agent-effort" class="form-label" data-i18n="lab.create.effortLabel">${escapeHtml(t('lab.create.effortLabel'))}</label>
            <div id="help-agent-effort" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.effortHelp">${escapeHtml(t('lab.create.effortHelp'))}</div>
            <select id="lab-agent-effort" class="form-select" aria-describedby="help-agent-effort">
              <option value="high" selected data-i18n="lab.create.effortHigh">${escapeHtml(t('lab.create.effortHigh'))}</option>
              <option value="medium">medium</option>
              <option value="low">low</option>
              <option value="xhigh">xhigh</option>
            </select>
          </div>
        </div>

        <div class="form-group" style="margin-bottom: 12px;">
          <label for="lab-agent-task" class="form-label" data-i18n="lab.create.taskLabel">${escapeHtml(t('lab.create.taskLabel'))}</label>
          <div id="help-agent-task" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.taskHelp">${escapeHtml(t('lab.create.taskHelp'))}</div>
          <textarea id="lab-agent-task" class="form-textarea" style="min-height: 56px;" placeholder="${escapeHtml(t('lab.create.taskPlaceholder'))}" data-i18n-placeholder="lab.create.taskPlaceholder" aria-describedby="help-agent-task">${escapeHtml(initialConfig.task || '')}</textarea>
        </div>

        <div class="form-group" style="margin-bottom: 12px;">
          <label for="lab-agent-verify-cmd" class="form-label" data-i18n="lab.create.verifyCmdLabel">${escapeHtml(t('lab.create.verifyCmdLabel'))}</label>
          <div id="help-agent-verify-cmd" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.verifyCmdHelp">${escapeHtml(t('lab.create.verifyCmdHelp'))}</div>
          <textarea id="lab-agent-verify-cmd" class="form-textarea code-editor" style="min-height: 48px;" placeholder='${escapeHtml(t('lab.create.verifyCmdPlaceholder'))}' data-i18n-placeholder="lab.create.verifyCmdPlaceholder" aria-describedby="help-agent-verify-cmd">${escapeHtml(defaultVerifyCommand)}</textarea>
        </div>

        <div class="form-group" style="margin-bottom: 12px;">
          <label for="lab-agent-verify-files" class="form-label" data-i18n="lab.create.verifyFilesLabel">${escapeHtml(t('lab.create.verifyFilesLabel'))}</label>
          <div id="help-agent-verify-files" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.verifyFilesHelp">${escapeHtml(t('lab.create.verifyFilesHelp'))}</div>
          <input type="text" id="lab-agent-verify-files" class="form-input font-mono" placeholder="tests/test_core.py, tests/verify.py" value="${escapeHtml((initialConfig.verificationFiles || []).map(f => typeof f === 'string' ? f : (f.path || '')).filter(Boolean).join(', '))}" aria-describedby="help-agent-verify-files">
        </div>

        <div class="form-group" style="margin-bottom: 12px;">
          <label for="lab-agent-output-files" class="form-label" data-i18n="lab.create.outputFilesLabel">${escapeHtml(t('lab.create.outputFilesLabel'))}</label>
          <div id="help-agent-output-files" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.outputFilesHelp">${escapeHtml(t('lab.create.outputFilesHelp'))}</div>
          <input type="text" id="lab-agent-output-files" class="form-input font-mono" placeholder="build/output.py, dist/bundle.js" value="${escapeHtml((initialConfig.outputFiles || []).map(f => typeof f === 'string' ? f : (f.path || '')).filter(Boolean).join(', '))}" aria-describedby="help-agent-output-files">
        </div>

        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 12px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-agent-repetitions" class="form-label" data-i18n="lab.create.repetitionsLabel">${escapeHtml(t('lab.create.repetitionsLabel'))}</label>
            <div id="help-agent-repetitions" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.repetitionsHelpAgent">${escapeHtml(t('lab.create.repetitionsHelpAgent'))}</div>
            <input type="number" id="lab-agent-repetitions" class="form-input font-mono" value="${initialConfig.repetitions || 3}" min="1" max="5" aria-describedby="help-agent-repetitions">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-agent-timeout" class="form-label" data-i18n="lab.create.timeoutLabel">${escapeHtml(t('lab.create.timeoutLabel'))}</label>
            <div id="help-agent-timeout" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.timeoutHelp">${escapeHtml(t('lab.create.timeoutHelp'))}</div>
            <input type="number" id="lab-agent-timeout" class="form-input font-mono" value="${initialConfig.timeoutSeconds || 240}" min="1" max="600" aria-describedby="help-agent-timeout">
          </div>
        </div>

        ${(candidateExplanation || candidateMemIds.length > 0 || candidateFileList.length > 0) ? `
          <div class="card" style="background: var(--bg-subtle); padding: 10px 12px; margin-bottom: 12px;">
            <div style="font-size: 11.5px; font-weight: 600; color: var(--text-secondary); margin-bottom: 6px;" data-i18n="lab.create.candidateConfigHeader">${escapeHtml(t('lab.create.candidateConfigHeader'))}</div>
            ${candidateExplanation ? `
              <div style="font-size: 11px; line-height: 1.45; color: var(--text-main); margin-bottom: 6px;">${escapeHtml(candidateExplanation)}</div>
            ` : ''}
            ${candidateMemIds.length > 0 ? `
              <div style="font-size: 11px; margin-bottom: 4px;">
                <span class="text-secondary" data-i18n="lab.create.candidateMemoriesCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: candidateMemIds.length }))}">${escapeHtml(t('lab.create.candidateMemoriesCount', { count: candidateMemIds.length }))}</span>
                <ul style="padding-left: 18px; margin: 4px 0 0 0; font-size: 11.5px;">
                  ${candidateMemIds.map(id => {
                    const info = resolveMemoryInfo(id);
                    return `<li><strong>${escapeHtml(info.title)}</strong> <span class="font-mono text-muted" style="font-size: 10px;">(ID: ${escapeHtml(id)})</span></li>`;
                  }).join('')}
                </ul>
              </div>
            ` : ''}
            ${candidateFileList.length > 0 ? `
              <div style="font-size: 11px; margin-top: 6px;">
                <span class="text-secondary" data-i18n="lab.create.candidateFilesCount" data-i18n-params="${escapeHtml(JSON.stringify({ count: candidateFileList.length }))}">${escapeHtml(t('lab.create.candidateFilesCount', { count: candidateFileList.length }))}</span>
                <ul style="padding-left: 18px; margin: 4px 0 0 0; font-family: var(--font-mono); font-size: 11px;">
                  ${candidateFileList.map(f => `<li>${escapeHtml(f.path)} <span class="text-muted" style="font-size: 10px;" data-i18n="lab.create.fileChars" data-i18n-params="${escapeHtml(JSON.stringify({ count: (f.content || '').length }))}">${escapeHtml(t('lab.create.fileChars', { count: (f.content || '').length }))}</span></li>`).join('')}
                </ul>
              </div>
            ` : ''}
          </div>
        ` : ''}

        <details class="card" style="margin-bottom: 12px; padding: 10px 12px;">
          <summary style="font-size: 11px; cursor: pointer; color: var(--text-muted); user-select: none;" data-i18n="lab.create.advancedAgentSummary">${escapeHtml(t('lab.create.advancedAgentSummary'))}</summary>
          <div class="form-group" style="margin-top: 10px; margin-bottom: 10px;">
            <label for="lab-agent-executable" class="form-label" data-i18n="lab.create.executableLabel">${escapeHtml(t('lab.create.executableLabel'))}</label>
            <div id="help-agent-exec" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.executableHelp">${escapeHtml(t('lab.create.executableHelp'))}</div>
            <input type="text" id="lab-agent-executable" class="form-input font-mono" placeholder="${escapeHtml(t('lab.create.executablePlaceholder'))}" data-i18n-placeholder="lab.create.executablePlaceholder" value="${escapeHtml(initialConfig.executable || 'codex')}" aria-describedby="help-agent-exec">
          </div>
          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 8px;">
            <div class="form-group" style="margin-bottom: 0;">
              <label for="lab-agent-baseline-json" class="form-label" style="font-size: 10.5px;">Baseline JSON</label>
              <textarea id="lab-agent-baseline-json" class="form-textarea code-editor" style="min-height: 70px;">${escapeHtml(defaultBaseline)}</textarea>
            </div>
            <div class="form-group" style="margin-bottom: 0;">
              <label for="lab-agent-candidate-json" class="form-label" style="font-size: 10.5px;">Candidate JSON</label>
              <textarea id="lab-agent-candidate-json" class="form-textarea code-editor" style="min-height: 70px;">${escapeHtml(defaultCandidate)}</textarea>
            </div>
          </div>
        </details>
      </div>

      <!-- Command Mode Form -->
      <div id="lab-section-cmd" class="${currentMode === 'command' ? '' : 'hidden'}">
        <div class="form-group" style="margin-bottom: 12px;">
          <label for="lab-cmd-title" class="form-label" data-i18n="lab.create.titleLabel">${escapeHtml(t('lab.create.titleLabel'))}</label>
          <input type="text" id="lab-cmd-title" class="form-input" placeholder="${escapeHtml(t('lab.create.cmdTitlePlaceholder'))}" data-i18n-placeholder="lab.create.cmdTitlePlaceholder" value="${escapeHtml(initialConfig.title || '确定性命令对照实验')}">
        </div>

        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 12px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-cmd-project" class="form-label" data-i18n="lab.create.projectLabel">${escapeHtml(t('lab.create.projectLabel'))}</label>
            <select id="lab-cmd-project" class="form-select">
              <option value="" ${!selectedProject ? 'selected' : ''} data-i18n="lab.create.selectProject">${escapeHtml(t('lab.create.selectProject'))}</option>
              ${(state.registeredProjects || []).map(p => {
                const val = p.path || p.id;
                return `<option value="${escapeHtml(val)}" ${selectedProject === val ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>`;
              }).join('')}
            </select>
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-cmd-kind" class="form-label" data-i18n="lab.create.kindLabel">${escapeHtml(t('lab.create.kindLabel'))}</label>
            <select id="lab-cmd-kind" class="form-select">
              <option value="context" data-i18n="lab.create.kindContextCmdOption">${escapeHtml(t('lab.create.kindContextCmdOption'))}</option>
              <option value="memory" data-i18n="lab.create.kindMemoryCmdOption">${escapeHtml(t('lab.create.kindMemoryCmdOption'))}</option>
              <option value="workflow" data-i18n="lab.create.kindWorkflowOption">${escapeHtml(t('lab.create.kindWorkflowOption'))}</option>
            </select>
          </div>
        </div>

        <div class="form-group" style="margin-bottom: 12px;">
          <label for="lab-cmd-command" class="form-label" data-i18n="lab.create.cmdCommandLabel">${escapeHtml(t('lab.create.cmdCommandLabel'))}</label>
          <div id="help-cmd-command" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.cmdCommandHelp">${escapeHtml(t('lab.create.cmdCommandHelp'))}</div>
          <textarea id="lab-cmd-command" class="form-textarea code-editor" style="min-height: 48px;" aria-describedby="help-cmd-command">${escapeHtml(defaultCommand)}</textarea>
        </div>

        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-bottom: 12px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-cmd-repetitions" class="form-label" data-i18n="lab.create.repetitionsLabel">${escapeHtml(t('lab.create.repetitionsLabel'))}</label>
            <div id="help-cmd-repetitions" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.repetitionsHelpCmd">${escapeHtml(t('lab.create.repetitionsHelpCmd'))}</div>
            <input type="number" id="lab-cmd-repetitions" class="form-input font-mono" value="${initialConfig.repetitions || 1}" min="1" max="5" aria-describedby="help-cmd-repetitions">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label for="lab-cmd-timeout" class="form-label" data-i18n="lab.create.timeoutLabel">${escapeHtml(t('lab.create.timeoutLabel'))}</label>
            <div id="help-cmd-timeout" class="form-help" style="margin-bottom: 4px;" data-i18n="lab.create.timeoutHelp">${escapeHtml(t('lab.create.timeoutHelp'))}</div>
            <input type="number" id="lab-cmd-timeout" class="form-input font-mono" value="${initialConfig.timeoutSeconds || 60}" min="1" max="600" aria-describedby="help-cmd-timeout">
          </div>
        </div>

        <details class="card" style="margin-bottom: 12px; padding: 10px 12px;">
          <summary style="font-size: 11px; cursor: pointer; color: var(--text-muted); user-select: none;" data-i18n="lab.create.advancedCmdSummary">${escapeHtml(t('lab.create.advancedCmdSummary'))}</summary>
          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 8px;">
            <div class="form-group" style="margin-bottom: 0;">
              <label for="lab-cmd-baseline" class="form-label" style="font-size: 10.5px;">Baseline JSON</label>
              <textarea id="lab-cmd-baseline" class="form-textarea code-editor" style="min-height: 70px;">${escapeHtml(defaultBaseline)}</textarea>
            </div>
            <div class="form-group" style="margin-bottom: 0;">
              <label for="lab-cmd-candidate" class="form-label" style="font-size: 10.5px;">Candidate JSON</label>
              <textarea id="lab-cmd-candidate" class="form-textarea code-editor" style="min-height: 70px;">${escapeHtml(defaultCandidate)}</textarea>
            </div>
          </div>
        </details>
      </div>
    `;

    openModal({ key: 'lab.modal.createTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-lab" data-i18n="lab.actions.cancel">${escapeHtml(t('lab.actions.cancel'))}</button>
      <button class="btn btn-primary" id="btn-save-lab" data-i18n="lab.actions.submitLab">${escapeHtml(t('lab.actions.submitLab'))}</button>
    `);

    const thisModalId = currentModalInstance;

    document.querySelectorAll('.mode-switch-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const mode = btn.getAttribute('data-target-mode');
        currentMode = mode;
        document.querySelectorAll('.mode-switch-btn').forEach(b => {
          b.classList.remove('active');
          b.setAttribute('aria-selected', 'false');
        });
        btn.classList.add('active');
        btn.setAttribute('aria-selected', 'true');
        if (mode === 'codex_agent') {
          document.getElementById('lab-section-agent').classList.remove('hidden');
          document.getElementById('lab-section-cmd').classList.add('hidden');
        } else {
          document.getElementById('lab-section-agent').classList.add('hidden');
          document.getElementById('lab-section-cmd').classList.remove('hidden');
        }
      });
    });

    document.getElementById('btn-cancel-lab').addEventListener('click', closeModal);
    document.getElementById('btn-save-lab').addEventListener('click', async () => {
      const submitBtn = document.getElementById('btn-save-lab');

      if (currentMode === 'codex_agent') {
        const title = document.getElementById('lab-agent-title').value.trim();
        const project = (document.getElementById('lab-agent-project')?.value || '').trim();
        const kind = document.getElementById('lab-agent-kind').value;
        const model = document.getElementById('lab-agent-model').value.trim();
        const reasoningEffort = document.getElementById('lab-agent-effort').value;
        const task = document.getElementById('lab-agent-task').value.trim();
        const executable = (document.getElementById('lab-agent-executable')?.value.trim()) || 'codex';

        const rawTimeout = document.getElementById('lab-agent-timeout').value.trim();
        if (!rawTimeout || !/^\d+$/.test(rawTimeout)) {
          showToast({ key: 'lab.validation.timeoutRange' }, 'error');
          return;
        }
        const timeoutSeconds = Number(rawTimeout);
        if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 600) {
          showToast({ key: 'lab.validation.timeoutRange' }, 'error');
          return;
        }

        const rawRep = document.getElementById('lab-agent-repetitions').value.trim();
        if (!rawRep || !/^\d+$/.test(rawRep)) {
          showToast({ key: 'lab.validation.repetitionsRange' }, 'error');
          return;
        }
        const repetitions = Number(rawRep);
        if (!Number.isInteger(repetitions) || repetitions < 1 || repetitions > 5) {
          showToast({ key: 'lab.validation.repetitionsRange' }, 'error');
          return;
        }

        if (!title) {
          showToast({ key: 'lab.validation.titleRequired' }, 'error');
          return;
        }

        if (!project) {
          showToast({ key: 'lab.validation.projectRequired' }, 'error');
          return;
        }

        if (!model) {
          showToast({ key: 'lab.validation.modelRequired' }, 'error');
          return;
        }
        if (!/^[a-zA-Z0-9][a-zA-Z0-9._:-]{0,127}$/.test(model)) {
          showToast({ key: 'lab.validation.modelInvalid' }, 'error');
          return;
        }

        if (!task) {
          showToast({ key: 'lab.validation.taskRequired' }, 'error');
          return;
        }

        let verifyCmdArr = [];
        try {
          verifyCmdArr = JSON.parse(document.getElementById('lab-agent-verify-cmd').value);
          if (!Array.isArray(verifyCmdArr) || verifyCmdArr.length === 0) {
            const err = new Error(t('lab.validation.verifyCmdArray'));
            err.i18nDescriptor = { key: 'lab.validation.verifyCmdArray' };
            throw err;
          }
          if (typeof verifyCmdArr[0] !== 'string' || !verifyCmdArr[0].trim()) {
            const err = new Error(t('lab.validation.verifyCmdExe'));
            err.i18nDescriptor = { key: 'lab.validation.verifyCmdExe' };
            throw err;
          }
          for (let idx = 0; idx < verifyCmdArr.length; idx++) {
            if (typeof verifyCmdArr[idx] !== 'string') {
              const err = new Error(t('lab.validation.verifyCmdArgv', { index: idx + 1 }));
              err.i18nDescriptor = { key: 'lab.validation.verifyCmdArgv', params: { index: idx + 1 } };
              throw err;
            }
          }
        } catch (err) {
          if (err && err.i18nDescriptor) {
            showToast(err.i18nDescriptor, 'error');
          } else {
            showToast({ key: 'lab.validation.verifyCmdFormat', params: { error: err.message } }, 'error');
          }
          return;
        }

        const rawVerifyFiles = document.getElementById('lab-agent-verify-files').value;
        const verifyFiles = rawVerifyFiles.split(/[\n,]/).map(s => s.trim()).filter(Boolean);
        if (verifyFiles.length === 0 || verifyFiles.length > 32) {
          showToast({ key: 'lab.validation.verifyFilesCount' }, 'error');
          return;
        }
        if (new Set(verifyFiles).size !== verifyFiles.length) {
          showToast({ key: 'lab.validation.verifyFilesDuplicate' }, 'error');
          return;
        }

        const rawOutputFiles = document.getElementById('lab-agent-output-files').value;
        const outputFiles = rawOutputFiles.split(/[\n,]/).map(s => s.trim()).filter(Boolean);
        if (outputFiles.length === 0 || outputFiles.length > 32) {
          showToast({ key: 'lab.validation.outputFilesCount' }, 'error');
          return;
        }
        if (new Set(outputFiles).size !== outputFiles.length) {
          showToast({ key: 'lab.validation.outputFilesDuplicate' }, 'error');
          return;
        }

        const overlap = verifyFiles.filter(p => outputFiles.includes(p));
        if (overlap.length > 0) {
          showToast({ key: 'lab.validation.overlapFiles', params: { files: overlap.join(', ') } }, 'error');
          return;
        }

        let baselineObj = {};
        try {
          baselineObj = JSON.parse(document.getElementById('lab-agent-baseline-json').value);
          if (typeof baselineObj !== 'object' || Array.isArray(baselineObj) || baselineObj === null) {
            const err = new Error(t('lab.validation.baselineJsonObj'));
            err.i18nDescriptor = { key: 'lab.validation.baselineJsonObj' };
            throw err;
          }
        } catch (err) {
          if (err && err.i18nDescriptor) {
            showToast(err.i18nDescriptor, 'error');
          } else {
            showToast({ key: 'lab.validation.baselineJsonFormat', params: { error: err.message } }, 'error');
          }
          return;
        }

        let candidateObj = {};
        try {
          candidateObj = JSON.parse(document.getElementById('lab-agent-candidate-json').value);
          if (typeof candidateObj !== 'object' || Array.isArray(candidateObj) || candidateObj === null) {
            const err = new Error(t('lab.validation.candidateJsonObj'));
            err.i18nDescriptor = { key: 'lab.validation.candidateJsonObj' };
            throw err;
          }
        } catch (err) {
          if (err && err.i18nDescriptor) {
            showToast(err.i18nDescriptor, 'error');
          } else {
            showToast({ key: 'lab.validation.candidateJsonFormat', params: { error: err.message } }, 'error');
          }
          return;
        }

        const payload = {
          title,
          project,
          kind,
          agent: {
            provider: 'codex',
            executable: executable,
            model,
            reasoningEffort
          },
          task,
          verificationCommand: verifyCmdArr,
          verificationFiles: verifyFiles,
          outputFiles: outputFiles,
          timeoutSeconds,
          repetitions,
          baseline: baselineObj,
          candidate: candidateObj
        };

        if (sourceSugId) {
          payload.sourceSuggestionId = sourceSugId;
        }

        submitBtn.disabled = true;
        window.VelaI18n.setElementDescriptor(submitBtn, { key: 'lab.actions.submitting' });

        try {
          const res = await callBridge('lab.run', payload);
          if (thisModalId !== currentModalInstance) return;
          closeModal();
          showLabCreatedPendingModal(payload.title, res && res.approvalId, project);
          await refreshDashboard(true, true);
        } catch (err) {
          if (thisModalId !== currentModalInstance) return;
          showToast({ key: 'lab.actions.createAgentFailed', params: { error: err.message } }, 'error');
          submitBtn.disabled = false;
          window.VelaI18n.setElementDescriptor(submitBtn, { key: 'lab.actions.submitLab' });
        }

      } else {
        // Command Mode
        const title = document.getElementById('lab-cmd-title').value.trim();
        const project = (document.getElementById('lab-cmd-project')?.value || '').trim();
        const kind = document.getElementById('lab-cmd-kind').value;

        const rawTimeout = document.getElementById('lab-cmd-timeout').value.trim();
        if (!rawTimeout || !/^\d+$/.test(rawTimeout)) {
          showToast({ key: 'lab.validation.timeoutRange' }, 'error');
          return;
        }
        const timeoutSeconds = Number(rawTimeout);
        if (!Number.isInteger(timeoutSeconds) || timeoutSeconds < 1 || timeoutSeconds > 600) {
          showToast({ key: 'lab.validation.timeoutRange' }, 'error');
          return;
        }

        const rawRep = document.getElementById('lab-cmd-repetitions').value.trim();
        if (!rawRep || !/^\d+$/.test(rawRep)) {
          showToast({ key: 'lab.validation.repetitionsRange' }, 'error');
          return;
        }
        const repetitions = Number(rawRep);
        if (!Number.isInteger(repetitions) || repetitions < 1 || repetitions > 5) {
          showToast({ key: 'lab.validation.repetitionsRange' }, 'error');
          return;
        }

        if (!title) {
          showToast({ key: 'lab.validation.titleRequired' }, 'error');
          return;
        }

        if (!project) {
          showToast({ key: 'lab.validation.projectRequired' }, 'error');
          return;
        }

        let commandArr = [];
        try {
          commandArr = JSON.parse(document.getElementById('lab-cmd-command').value);
          if (!Array.isArray(commandArr) || commandArr.length === 0) {
            const err = new Error(t('lab.validation.cmdArray'));
            err.i18nDescriptor = { key: 'lab.validation.cmdArray' };
            throw err;
          }
          if (typeof commandArr[0] !== 'string' || !commandArr[0].trim()) {
            const err = new Error(t('lab.validation.cmdExe'));
            err.i18nDescriptor = { key: 'lab.validation.cmdExe' };
            throw err;
          }
          for (let idx = 0; idx < commandArr.length; idx++) {
            if (typeof commandArr[idx] !== 'string') {
              const err = new Error(t('lab.validation.cmdArgv', { index: idx + 1 }));
              err.i18nDescriptor = { key: 'lab.validation.cmdArgv', params: { index: idx + 1 } };
              throw err;
            }
          }
        } catch (err) {
          if (err && err.i18nDescriptor) {
            showToast(err.i18nDescriptor, 'error');
          } else {
            showToast({ key: 'lab.validation.cmdFormat', params: { error: err.message } }, 'error');
          }
          return;
        }

        let baselineObj = {};
        try {
          baselineObj = JSON.parse(document.getElementById('lab-cmd-baseline').value);
          if (typeof baselineObj !== 'object' || Array.isArray(baselineObj) || baselineObj === null) {
            const err = new Error(t('lab.validation.baselineJsonObj'));
            err.i18nDescriptor = { key: 'lab.validation.baselineJsonObj' };
            throw err;
          }
        } catch (err) {
          if (err && err.i18nDescriptor) {
            showToast(err.i18nDescriptor, 'error');
          } else {
            showToast({ key: 'lab.validation.baselineJsonFormat', params: { error: err.message } }, 'error');
          }
          return;
        }

        let candidateObj = {};
        try {
          candidateObj = JSON.parse(document.getElementById('lab-cmd-candidate').value);
          if (typeof candidateObj !== 'object' || Array.isArray(candidateObj) || candidateObj === null) {
            const err = new Error(t('lab.validation.candidateJsonObj'));
            err.i18nDescriptor = { key: 'lab.validation.candidateJsonObj' };
            throw err;
          }
        } catch (err) {
          if (err && err.i18nDescriptor) {
            showToast(err.i18nDescriptor, 'error');
          } else {
            showToast({ key: 'lab.validation.candidateJsonFormat', params: { error: err.message } }, 'error');
          }
          return;
        }

        submitBtn.disabled = true;
        window.VelaI18n.setElementDescriptor(submitBtn, { key: 'lab.actions.submitting' });

        try {
          const res = await callBridge('lab.run', {
            title,
            project,
            kind,
            command: commandArr,
            baseline: baselineObj,
            candidate: candidateObj,
            timeoutSeconds,
            repetitions
          });
          if (thisModalId !== currentModalInstance) return;
          closeModal();
          showLabCreatedPendingModal(title, res && res.approvalId, project);
          await refreshDashboard(true, true);
        } catch (err) {
          if (thisModalId !== currentModalInstance) return;
          showToast({ key: 'lab.actions.createCmdFailed', params: { error: err.message } }, 'error');
          submitBtn.disabled = false;
          window.VelaI18n.setElementDescriptor(submitBtn, { key: 'lab.actions.submitLab' });
        }
      }
    });
  }

  function showLabCreatedPendingModal(title, approvalId, project = null) {
    openModal({ key: 'lab.modal.pendingQueueTitle' }, `
      <div style="font-size: 13px; line-height: 1.6; color: var(--text-secondary);">
        <p><span data-i18n="lab.pendingModal.createdPrefix">${escapeHtml(t('lab.pendingModal.createdPrefix'))}</span> <strong>${escapeHtml(title || '')}</strong> <span data-i18n="lab.pendingModal.createdSuffix">${escapeHtml(t('lab.pendingModal.createdSuffix'))}</span></p>
        <p style="margin-top: 8px;">
          <span data-i18n="lab.pendingModal.currentStatusLabel">${escapeHtml(t('lab.pendingModal.currentStatusLabel'))}</span>: <span class="status-badge status-amber" data-i18n="lab.state.pendingApprovalBadge">${escapeHtml(t('lab.state.pendingApprovalBadge'))}</span>
        </p>
        <p style="margin-top: 8px;" data-i18n="lab.pendingModal.securityNotice">
          ${escapeHtml(t('lab.pendingModal.securityNotice'))}
        </p>
      </div>
    `, `
      <button class="btn btn-secondary" id="btn-stay-page" data-i18n="lab.actions.stayOnPage">${escapeHtml(t('lab.actions.stayOnPage'))}</button>
      <button class="btn btn-primary" id="btn-route-inbox" data-i18n="lab.actions.goToInbox">${escapeHtml(t('lab.actions.goToInbox'))}</button>
    `);

    document.getElementById('btn-stay-page').addEventListener('click', closeModal);
    document.getElementById('btn-route-inbox').addEventListener('click', async () => {
      closeModal();
      if (project && state.currentProject !== project) {
        state.currentProject = project;
      }
      navigateTo('inbox');
      await refreshDashboard(true, true);
    });
  }

  let labDetailSequence = 0;

  async function openLabCompareDrawer(evalId) {
    const thisSeq = ++labDetailSequence;
    const thisPage = state.currentPage;
    const thisProject = state.currentProject;
    state.selectedEvalId = evalId;
    openDrawer({ key: 'lab.drawer.loadingTitle' }, { key: 'lab.drawer.subtitle' });

    try {
      const cmp = await callBridge('lab.compare', { id: evalId });
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== labDetailSequence || state.selectedEvalId !== evalId || !isDrawerOpen || state.currentPage !== thisPage || state.currentProject !== thisProject) {
        return;
      }
      if (!cmp) {
        const err = new Error(t('lab.drawer.dataNotFound'));
        err.i18nKey = 'lab.drawer.dataNotFound';
        throw err;
      }

      const drawerTitleParam = cmp.title || { key: 'lab.drawer.defaultResultTitle' };
      const drawerSubtitleParam = evalId ? { key: 'lab.drawer.idSubtitle', params: { id: evalId.substring(0, 8) } } : { key: 'lab.drawer.subtitle' };
      setDrawerTitle(drawerTitleParam, drawerSubtitleParam);
      const st = (cmp.state || '').toLowerCase();
      const isPending = (st === 'pending_approval' || st === 'pending approval');
      const isCompleted = (st === 'completed');
      const isAgent = (cmp.evaluator === 'codex_agent');
      const results = cmp.results || [];
      const summary = cmp.summary || {};
      const decision = summary.decision;
      const isReadyForReview = (decision === 'ready_for_review');
      const candidateSnapshots = (cmp.candidate && cmp.candidate.memories) || [];
      const candidateFiles = (cmp.candidate && cmp.candidate.files) || [];
      const candidateContext = (cmp.candidate && cmp.candidate.context) || '';
      const memoryContext = candidateSnapshots.map(m => `${m.title || ''}\n${m.content || ''}`).join('\n\n');
      const memoryOnly = candidateSnapshots.length > 0 && candidateFiles.length === 0 && (!candidateContext || candidateContext === memoryContext);
      const isAlreadyPromoted = !!cmp.promotionId;

      const isPromotionEligible = isCompleted && isAgent && isReadyForReview && memoryOnly && !isAlreadyPromoted;

      if (isPromotionEligible) {
        setDrawerCustomActions(`<button id="btn-drawer-promote-eval" class="btn btn-primary btn-sm" data-i18n="lab.actions.promoteMemory">${escapeHtml(t('lab.actions.promoteMemory'))}</button>`);
        document.getElementById('btn-drawer-promote-eval').addEventListener('click', () => {
          openConfirmPromoteModal(cmp);
        });
      } else if (isAlreadyPromoted) {
        setDrawerCustomActions(`<span class="status-badge status-sage" data-i18n="lab.state.promotedActive">${escapeHtml(t('lab.state.promotedActive'))}</span>`);
      } else {
        setDrawerCustomActions('');
      }

      // Verification command display
      const cmdArr = Array.isArray(cmp.verificationCommand) ? cmp.verificationCommand : (Array.isArray(cmp.command) ? cmp.command : []);
      const cmdExe = cmdArr.length > 0 ? cmdArr[0] : '-';
      const cmdArgvStr = JSON.stringify(cmdArr.slice(1));

      const drawerBody = document.getElementById('drawer-content');

      drawerBody.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title" data-i18n="lab.drawer.basicInfoTitle">${escapeHtml(t('lab.drawer.basicInfoTitle'))}</span>
            ${getEvalStateBadge(cmp.state)}
          </div>
          <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
            <div><span class="text-secondary" data-i18n="lab.drawer.kindLabel">${escapeHtml(t('lab.drawer.kindLabel'))}</span>: ${escapeHtml(cmp.evaluationKind || cmp.kind || 'context')}</div>
            <div><span class="text-secondary" data-i18n="lab.drawer.evaluatorLabel">${escapeHtml(t('lab.drawer.evaluatorLabel'))}</span>: <span class="code-badge">${isAgent ? 'Codex Agent' : 'deterministic_command'}</span></div>
            <div><span class="text-secondary">Git Commit:</span> <span class="font-mono">${cmp.commit ? escapeHtml(cmp.commit.substring(0, 8)) : '-'}</span></div>
            <div><span class="text-secondary" data-i18n="lab.drawer.repetitionsLabel">${escapeHtml(t('lab.drawer.repetitionsLabel'))}</span>: <span class="font-mono">${cmp.repetitions !== null && cmp.repetitions !== undefined ? tHtml('lab.drawer.repetitionsSummary', { rep: cmp.repetitions, total: cmp.repetitions * 2 }) : tHtml('lab.metric.notRecorded')}</span></div>
            <div><span class="text-secondary" data-i18n="lab.drawer.timeoutLabel">${escapeHtml(t('lab.drawer.timeoutLabel'))}</span>: <span class="font-mono">${cmp.timeoutSeconds !== null && cmp.timeoutSeconds !== undefined ? `${cmp.timeoutSeconds}s` : tHtml('lab.metric.notRecorded')}</span></div>
            ${isAgent ? `
              <div><span class="text-secondary" data-i18n="lab.drawer.requestedModelLabel">${escapeHtml(t('lab.drawer.requestedModelLabel'))}</span>: <span class="font-mono"><strong>${(cmp.modelIdentity?.requested || cmp.agent?.model) ? escapeHtml(cmp.modelIdentity?.requested || cmp.agent?.model) : tHtml('lab.metric.notSpecified')}</strong></span></div>
              <div style="grid-column: 1 / -1;"><span class="text-secondary" data-i18n="lab.drawer.serverVersionLabel">${escapeHtml(t('lab.drawer.serverVersionLabel'))}</span>: <span class="font-mono text-muted">${cmp.modelIdentity?.providerResolvedVersion ? escapeHtml(cmp.modelIdentity.providerResolvedVersion) : tHtml('lab.drawer.serverVersionOmitted')}</span></div>
              <div><span class="text-secondary" data-i18n="lab.drawer.effortLabel">${escapeHtml(t('lab.drawer.effortLabel'))}</span>: <span class="font-mono">${cmp.agent?.reasoningEffort ? escapeHtml(cmp.agent.reasoningEffort) : tHtml('lab.metric.notRecorded')}</span></div>
            ` : ''}
            <div style="grid-column: 1 / -1; margin-top: 4px;">
              <span class="text-secondary">${isAgent ? tHtml('lab.drawer.verifyCmdLabel') : tHtml('lab.drawer.execCmdLabel')}:</span>
              <div class="font-mono" style="font-size: 11px; margin-top: 2px; padding: 4px 6px; background: var(--bg-subtle); border-radius: 4px; border: 1px solid var(--border-color);">
                <span><span data-i18n="lab.drawer.programLabel">${escapeHtml(t('lab.drawer.programLabel'))}</span>: <strong>${escapeHtml(cmdExe)}</strong></span> ·
                <span>JSON argv: <code>${escapeHtml(cmdArgvStr)}</code></span>
              </div>
            </div>
            ${isAgent && cmp.task ? `
              <div style="grid-column: 1 / -1; margin-top: 4px;">
                <span class="text-secondary" data-i18n="lab.drawer.taskLabel">${escapeHtml(t('lab.drawer.taskLabel'))}</span>:
                <div style="font-size: 12px; line-height: 1.45; color: var(--text-main); margin-top: 2px; padding: 6px 8px; background: var(--bg-subtle); border-radius: 4px; border: 1px solid var(--border-color); white-space: pre-wrap;">${escapeHtml(cmp.task)}</div>
              </div>
            ` : ''}
            ${cmp.verificationFiles && cmp.verificationFiles.length > 0 ? `
              <div style="grid-column: 1 / -1; margin-top: 4px;">
                <details style="font-size: 11px;">
                  <summary style="cursor: pointer; color: var(--text-secondary);" data-i18n="lab.drawer.verifyFilesSummary" data-i18n-params="${escapeHtml(JSON.stringify({ count: cmp.verificationFiles.length }))}">${escapeHtml(t('lab.drawer.verifyFilesSummary', { count: cmp.verificationFiles.length }))}</summary>
                  <ul style="margin-top: 4px; padding-left: 18px; font-family: var(--font-mono); font-size: 10.5px; color: var(--text-muted);">
                    ${cmp.verificationFiles.map(f => `<li>${escapeHtml(typeof f === 'string' ? f : (f.path + (f.hash ? ' (' + f.hash.slice(0, 8) + ')' : '')))}</li>`).join('')}
                  </ul>
                </details>
              </div>
            ` : ''}
            ${cmp.outputFiles && cmp.outputFiles.length > 0 ? `
              <div style="grid-column: 1 / -1; margin-top: 4px;">
                <details style="font-size: 11px;">
                  <summary style="cursor: pointer; color: var(--text-secondary);" data-i18n="lab.drawer.outputFilesSummary" data-i18n-params="${escapeHtml(JSON.stringify({ count: cmp.outputFiles.length }))}">${escapeHtml(t('lab.drawer.outputFilesSummary', { count: cmp.outputFiles.length }))}</summary>
                  <ul style="margin-top: 4px; padding-left: 18px; font-family: var(--font-mono); font-size: 10.5px; color: var(--text-muted);">
                    ${cmp.outputFiles.map(f => `<li>${escapeHtml(f)}</li>`).join('')}
                  </ul>
                </details>
              </div>
            ` : ''}
            ${cmp.sourceSuggestionId ? `
              <div style="grid-column: 1 / -1; margin-top: 4px; font-size: 11px;">
                <span class="text-secondary" data-i18n="lab.drawer.linkedSuggestionLabel">${escapeHtml(t('lab.drawer.linkedSuggestionLabel'))}</span>:
                <span class="code-badge">${escapeHtml(cmp.sourceSuggestionId.substring(0, 8))}</span>
                ${cmp.sourceRelationship ? `<span class="badge-subtle">${escapeHtml(cmp.sourceRelationship)}</span>` : ''}
              </div>
            ` : ''}
            <div style="grid-column: 1 / -1; margin-top: 6px; font-size: 11px; color: var(--text-secondary); border-top: 1px dashed var(--border-color); padding-top: 6px;" data-i18n="lab.drawer.futureEffectNotice">
              ${escapeHtml(t('lab.drawer.futureEffectNotice'))}
            </div>
          </div>
        </div>

        ${isPending ? `
          <div class="empty-state">
            <div class="empty-state-title" data-i18n="lab.drawer.emptyPendingTitle">${escapeHtml(t('lab.drawer.emptyPendingTitle'))}</div>
            <div class="empty-state-desc" data-i18n="lab.drawer.emptyPendingDesc">${escapeHtml(t('lab.drawer.emptyPendingDesc'))}</div>
          </div>
        ` : `
          ${decision ? `
            <div class="lab-decision-banner ${isReadyForReview ? 'ready' : (decision === 'reject' ? 'reject' : 'inconclusive')}">
              <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 4px;">
                ${getEvalDecisionTitleNode(decision)}
                <span class="font-mono" style="font-size: 11px;">decision: ${escapeHtml(decision)}</span>
              </div>
              <div style="font-size: 12px; line-height: 1.45;" data-i18n="${getEvalDecisionExplanationKey(decision)}">${escapeHtml(getEvalDecisionExplanation(decision))}</div>
              ${summary.reasons && summary.reasons.length > 0 ? `
                <ul style="margin: 6px 0 0 0; padding-left: 18px; font-size: 11.5px;">
                  ${summary.reasons.map(r => `<li>${escapeHtml(r)}</li>`).join('')}
                </ul>
              ` : ''}
              ${summary.interpretation ? `
                <div style="font-size: 11px; margin-top: 6px; opacity: 0.85;">${escapeHtml(summary.interpretation)}</div>
              ` : ''}
            </div>
          ` : ''}

          ${isAlreadyPromoted ? `
            <div class="card" style="background: var(--status-sage-bg); border-color: var(--status-sage-border); padding: 8px 12px; margin-bottom: 12px;">
              <div style="font-size: 12px; color: var(--status-sage-text);">
                <strong data-i18n="lab.drawer.promotedCardTitle">${escapeHtml(t('lab.drawer.promotedCardTitle'))}</strong>
                <div style="font-size: 11px; margin-top: 2px;">
                  Promotion ID: <code>${escapeHtml(cmp.promotionId)}</code> · <span data-i18n="lab.drawer.statusLabel">${escapeHtml(t('lab.drawer.statusLabel'))}</span>: <span data-i18n="lab.state.active">${escapeHtml(t('lab.state.active'))}</span> · <span data-i18n="lab.drawer.promotedAtLabel">${escapeHtml(t('lab.drawer.promotedAtLabel'))}</span>: ${formatTime(cmp.promotedAt)}
                </div>
              </div>
            </div>
          ` : ''}

          <div class="lab-compare-grid">
            <div class="lab-variant-card baseline">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
                <span style="font-weight: 600; font-size: 13px;" data-i18n="lab.compare.baselineCardTitle">${escapeHtml(t('lab.compare.baselineCardTitle'))}</span>
                <span class="status-badge status-neutral">${formatFinitePassRate(summary.baseline?.passRate, isPending)}</span>
              </div>
              <div class="lab-metric-list">
                ${isAgent ? `
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.passRate">${escapeHtml(t('lab.metric.passRate'))}:</span>
                    <span class="lab-metric-val">${formatFinitePassRate(summary.baseline?.passRate, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.verifierSuccesses">${escapeHtml(t('lab.metric.verifierSuccesses'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.baseline?.successes, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.validRuns">${escapeHtml(t('lab.metric.validRuns'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.baseline?.validRuns, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.recordedRuns">${escapeHtml(t('lab.metric.recordedRuns'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.baseline?.runs, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.testExecRate">${escapeHtml(t('lab.metric.testExecRate'))}:</span>
                    <span class="lab-metric-val">${formatFinitePassRate(summary.baseline?.testExecutionRate, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.avgTokens">${escapeHtml(t('lab.metric.avgTokens'))}:</span>
                    <span class="lab-metric-val">${formatFiniteTokens(summary.baseline?.averageTokens, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.avgDuration">${escapeHtml(t('lab.metric.avgDuration'))}:</span>
                    <span class="lab-metric-val">${formatFiniteDuration(summary.baseline?.averageDurationMs, isPending)}</span>
                  </div>
                ` : `
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.passRateExit0">${escapeHtml(t('lab.metric.passRateExit0'))}:</span>
                    <span class="lab-metric-val">${formatFinitePassRate(summary.baseline?.passRate, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.successCount">${escapeHtml(t('lab.metric.successCount'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.baseline?.successes, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.recordedRuns">${escapeHtml(t('lab.metric.recordedRuns'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.baseline?.runs, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.avgDuration">${escapeHtml(t('lab.metric.avgDuration'))}:</span>
                    <span class="lab-metric-val">${formatFiniteDuration(summary.baseline?.averageDurationMs, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.runtimeVariance">${escapeHtml(t('lab.metric.runtimeVariance'))}:</span>
                    <span class="lab-metric-val">${summary.baseline?.runtimeVariance !== null && summary.baseline?.runtimeVariance !== undefined ? (Math.round(summary.baseline.runtimeVariance) + ' ms²') : tHtml('lab.metric.notProvided')}</span>
                  </div>
                `}
              </div>
              <div style="margin-top: 10px; padding-top: 6px; border-top: 1px dashed var(--border-color); font-size: 11px;">
                <div class="text-secondary" style="margin-bottom: 2px;" data-i18n="lab.compare.mountConfig">${escapeHtml(t('lab.compare.mountConfig'))}:</div>
                <div>${formatVariantSummary(cmp.baseline)}</div>
              </div>
            </div>

            <div class="lab-variant-card candidate">
              <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
                <span style="font-weight: 600; font-size: 13px;" data-i18n="lab.compare.candidateCardTitle">${escapeHtml(t('lab.compare.candidateCardTitle'))}</span>
                <span class="status-badge ${isReadyForReview ? 'status-sage' : (decision === 'reject' ? 'status-red' : 'status-amber')}">
                  ${formatFinitePassRate(summary.candidate?.passRate, isPending)}
                </span>
              </div>
              <div class="lab-metric-list">
                ${isAgent ? `
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.passRate">${escapeHtml(t('lab.metric.passRate'))}:</span>
                    <span class="lab-metric-val">${formatFinitePassRate(summary.candidate?.passRate, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.verifierSuccesses">${escapeHtml(t('lab.metric.verifierSuccesses'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.candidate?.successes, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.validRuns">${escapeHtml(t('lab.metric.validRuns'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.candidate?.validRuns, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.recordedRuns">${escapeHtml(t('lab.metric.recordedRuns'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.candidate?.runs, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.testExecRate">${escapeHtml(t('lab.metric.testExecRate'))}:</span>
                    <span class="lab-metric-val">${formatFinitePassRate(summary.candidate?.testExecutionRate, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.avgTokens">${escapeHtml(t('lab.metric.avgTokens'))}:</span>
                    <span class="lab-metric-val">${formatFiniteTokens(summary.candidate?.averageTokens, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.avgDuration">${escapeHtml(t('lab.metric.avgDuration'))}:</span>
                    <span class="lab-metric-val">${formatFiniteDuration(summary.candidate?.averageDurationMs, isPending)}</span>
                  </div>
                ` : `
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.passRateExit0">${escapeHtml(t('lab.metric.passRateExit0'))}:</span>
                    <span class="lab-metric-val">${formatFinitePassRate(summary.candidate?.passRate, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.successCount">${escapeHtml(t('lab.metric.successCount'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.candidate?.successes, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.recordedRuns">${escapeHtml(t('lab.metric.recordedRuns'))}:</span>
                    <span class="lab-metric-val">${formatFiniteCount(summary.candidate?.runs, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.avgDuration">${escapeHtml(t('lab.metric.avgDuration'))}:</span>
                    <span class="lab-metric-val">${formatFiniteDuration(summary.candidate?.averageDurationMs, isPending)}</span>
                  </div>
                  <div class="lab-metric-row">
                    <span class="lab-metric-label" data-i18n="lab.metric.runtimeVariance">${escapeHtml(t('lab.metric.runtimeVariance'))}:</span>
                    <span class="lab-metric-val">${summary.candidate?.runtimeVariance !== null && summary.candidate?.runtimeVariance !== undefined ? (Math.round(summary.candidate.runtimeVariance) + ' ms²') : tHtml('lab.metric.notProvided')}</span>
                  </div>
                `}
              </div>
              <div style="margin-top: 10px; padding-top: 6px; border-top: 1px dashed var(--border-color); font-size: 11px;">
                <div class="text-secondary" style="margin-bottom: 2px;" data-i18n="lab.compare.mountConfig">${escapeHtml(t('lab.compare.mountConfig'))}:</div>
                <div>${formatVariantSummary(cmp.candidate)}</div>
              </div>
            </div>
          </div>

          <div style="margin-top: 14px;">
            <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;" data-i18n="lab.compare.sampleDetailsHeader" data-i18n-params="${escapeHtml(JSON.stringify({ count: results.length }))}">${escapeHtml(t('lab.compare.sampleDetailsHeader', { count: results.length }))}</h3>
            ${results.length === 0 ? `<div style="font-size: 12px; color: var(--text-muted); padding: 8px 0;" data-i18n="lab.compare.emptySamples">${escapeHtml(t('lab.compare.emptySamples'))}</div>` : `
              <div class="lab-sample-list">
                ${results.map((r, i) => {
                  const isCand = r.variant === 'candidate';
                  const sideKey = isCand ? 'lab.compare.candidateSide' : 'lab.compare.baselineSide';
                  const repNum = r.repetition || (i + 1);

                  const agentExit = r.exitCode !== null && r.exitCode !== undefined ? String(r.exitCode) : tHtml('lab.metric.notProvided');
                  const agentDur = r.durationMs !== null && r.durationMs !== undefined ? `${r.durationMs}ms` : tHtml('lab.metric.notProvided');
                  const timedOutTag = r.timedOut ? `<span class="status-badge status-red" data-i18n="lab.state.timeout">${escapeHtml(t('lab.state.timeout'))}</span>` : '';
                  const tokenUsage = r.tokens !== null && r.tokens !== undefined ? `${r.tokens.toLocaleString()} tok` : tHtml('lab.metric.notProvided');

                  const verifierExit = r.verification ? (r.verification.exitCode !== null && r.verification.exitCode !== undefined ? String(r.verification.exitCode) : tHtml('lab.metric.notProvided')) : tHtml('lab.metric.notExecuted');
                  let intactBadge = `<span class="status-badge status-neutral" data-i18n="lab.state.notMeasured">${escapeHtml(t('lab.state.notMeasured'))}</span>`;
                  if (r.verificationIntact === true) {
                    intactBadge = `<span class="status-badge status-sage" data-i18n="lab.state.intactPass">${escapeHtml(t('lab.state.intactPass'))}</span>`;
                  } else if (r.verificationIntact === false) {
                    intactBadge = `<span class="status-badge status-red" data-i18n="lab.state.intactTampered">${escapeHtml(t('lab.state.intactTampered'))}</span>`;
                  }

                  let sessionLinkHtml = '';
                  const srcSessId = r.agentMetrics && r.agentMetrics.sourceSessionId;
                  if (srcSessId) {
                    const foundSession = findVelaSessionBySourceId(srcSessId, cmp.project);
                    if (foundSession) {
                      sessionLinkHtml = `
                        <button type="button" class="btn-open-source btn btn-ghost btn-sm" data-session-id="${escapeHtml(foundSession.id)}" data-i18n-title="lab.compare.sessionLinkTitle" data-i18n-params="${escapeHtml(JSON.stringify({ id: foundSession.id }))}" title="${escapeHtml(t('lab.compare.sessionLinkTitle', { id: foundSession.id }))}">
                          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg>
                          <span data-i18n="lab.compare.viewSession" data-i18n-params="${escapeHtml(JSON.stringify({ id: foundSession.id.slice(0, 8) }))}">${escapeHtml(t('lab.compare.viewSession', { id: foundSession.id.slice(0, 8) }))}</span>
                        </button>
                      `;
                    } else {
                      sessionLinkHtml = `<span class="text-muted" style="font-size: 10.5px;">Provider <span data-i18n="lab.compare.sessionIdLabel">${escapeHtml(t('lab.compare.sessionIdLabel'))}</span>: <code>${escapeHtml(srcSessId)}</code> (<span data-i18n="lab.compare.sessionNotIndexed">${escapeHtml(t('lab.compare.sessionNotIndexed'))}</span>)</span>`;
                    }
                  }

                  const rawCmd = r.agentCommand || r.command || [];
                  const sampleCmdExe = Array.isArray(rawCmd) && rawCmd.length > 0 ? rawCmd[0] : '-';
                  const sampleCmdArgv = Array.isArray(rawCmd) ? JSON.stringify(rawCmd.slice(1)) : '[]';

                  return `
                    <div class="lab-sample-card">
                      <div class="lab-sample-header">
                        <div>
                          <span class="code-badge" style="${isCand ? 'border-color: var(--color-accent);' : ''}">${tHtml(sideKey)} · ${tHtml('lab.compare.repetitionItem', { rep: repNum })}</span>
                        </div>
                        <div style="display: flex; gap: 6px; align-items: center;">
                          ${timedOutTag}
                          ${intactBadge}
                        </div>
                      </div>

                      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 6px; font-size: 11px; margin-bottom: 6px;">
                        <div><span class="text-secondary" data-i18n="lab.compare.agentProcessLabel">${escapeHtml(t('lab.compare.agentProcessLabel'))}</span>: Exit: <strong>${agentExit}</strong> · ${agentDur} · ${tokenUsage}</div>
                        <div><span class="text-secondary">${isAgent ? tHtml('lab.compare.verifierLabel') : tHtml('lab.compare.cmdStatusLabel')}:</span> Exit: <strong>${verifierExit}</strong></div>
                      </div>

                      <div style="font-size: 11px; margin-bottom: 6px;">
                        <span class="text-secondary" data-i18n="lab.compare.execCmdLabel">${escapeHtml(t('lab.compare.execCmdLabel'))}</span>:
                        <span class="font-mono"><span data-i18n="lab.compare.exeFileLabel">${escapeHtml(t('lab.compare.exeFileLabel'))}</span>: <strong>${escapeHtml(sampleCmdExe)}</strong> · argv: <code>${escapeHtml(sampleCmdArgv)}</code></span>
                      </div>

                      ${sessionLinkHtml ? `<div style="margin-bottom: 6px;">${sessionLinkHtml}</div>` : ''}

                      <div style="display: flex; flex-direction: column; gap: 4px; margin-top: 6px;">
                        <details style="font-size: 11px;">
                          <summary style="cursor: pointer; color: var(--text-secondary);" data-i18n="lab.compare.outputSummary" data-i18n-params="${escapeHtml(JSON.stringify({ count: (r.output || '').length }))}">${escapeHtml(t('lab.compare.outputSummary', { count: (r.output || '').length }))}</summary>
                          <div class="code-view" style="font-size: 11px; margin-top: 4px; max-height: 120px; overflow-y: auto;">${r.output ? escapeHtml(r.output) : tHtml('lab.compare.noOutput')}</div>
                        </details>
                        ${r.verification && r.verification.output ? `
                          <details style="font-size: 11px;">
                            <summary style="cursor: pointer; color: var(--text-secondary);" data-i18n="lab.compare.verifierOutputSummary" data-i18n-params="${escapeHtml(JSON.stringify({ count: (r.verification.output || '').length }))}">${escapeHtml(t('lab.compare.verifierOutputSummary', { count: (r.verification.output || '').length }))}</summary>
                            <div class="code-view" style="font-size: 11px; margin-top: 4px; max-height: 120px; overflow-y: auto;">${escapeHtml(r.verification.output)}</div>
                          </details>
                        ` : ''}
                      </div>
                    </div>
                  `;
                }).join('')}
              </div>
            `}
          </div>
        `}
      `;
    } catch (err) {
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== labDetailSequence || state.selectedEvalId !== evalId || !isDrawerOpen || state.currentPage !== thisPage || state.currentProject !== thisProject) {
        return;
      }
      setDrawerTitle({ key: 'lab.drawer.failedTitle' }, { key: 'lab.drawer.errorSubtitle' });
      const errHtml = (err && err.i18nKey === 'lab.drawer.dataNotFound')
        ? tHtml('lab.drawer.dataNotFound')
        : escapeHtml(err.message);
      document.getElementById('drawer-content').innerHTML = `
        <div class="alert-banner alert-danger"><span data-i18n="lab.drawer.compareLoadFailed">${escapeHtml(t('lab.drawer.compareLoadFailed'))}</span>: ${errHtml}</div>
      `;
    }
  }

  const openLabDetail = openLabCompareDrawer;

  function openConfirmPromoteModal(cmp) {
    const mems = (cmp.candidate && cmp.candidate.memories) || [];
    if (mems.length === 0) {
      showToast({ key: 'lab.promote.noCandidateMems' }, 'info');
      return;
    }

    const modalBody = `
      <div style="font-size: 13px; line-height: 1.5; color: var(--text-secondary); margin-bottom: 12px;" data-i18n="lab.promote.confirmPrompt" data-i18n-params="${escapeHtml(JSON.stringify({ id: cmp.id.substring(0, 8), count: mems.length }))}">
        ${escapeHtml(t('lab.promote.confirmPrompt', { id: cmp.id.substring(0, 8), count: mems.length }))}
      </div>

      <div class="card" style="margin-bottom: 12px; padding: 10px 12px; background: var(--bg-subtle);">
        <div style="font-size: 11px; font-weight: 600; color: var(--text-secondary); margin-bottom: 6px;" data-i18n="lab.promote.memoriesToActivate">${escapeHtml(t('lab.promote.memoriesToActivate'))}:</div>
        <ul style="padding-left: 18px; margin: 0; font-size: 12px; color: var(--text-main);">
          ${mems.map(m => `
            <li style="margin-bottom: 4px;">
              <strong>${escapeHtml(m.title || m.id)}</strong>
              <span class="font-mono text-muted" style="font-size: 10.5px;">(ID: ${escapeHtml(m.id)})</span>
            </li>
          `).join('')}
        </ul>
      </div>

      <div class="alert-banner alert-neutral" style="font-size: 11px; line-height: 1.45;">
        <strong data-i18n="lab.promote.engineeringNoticeTitle">${escapeHtml(t('lab.promote.engineeringNoticeTitle'))}</strong>:
        <span data-i18n="lab.promote.engineeringNoticeBody">${escapeHtml(t('lab.promote.engineeringNoticeBody'))}</span>
      </div>

      <div id="promote-error-container" class="hidden" style="margin-top: 10px;"></div>
    `;

    openModal({ key: 'lab.modal.promoteTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-promote" data-i18n="lab.actions.cancel">${escapeHtml(t('lab.actions.cancel'))}</button>
      <button class="btn btn-primary" id="btn-confirm-promote" data-i18n="lab.actions.confirmPromote">${escapeHtml(t('lab.actions.confirmPromote'))}</button>
    `);

    document.getElementById('btn-cancel-promote').addEventListener('click', closeModal);
    document.getElementById('btn-confirm-promote').addEventListener('click', async () => {
      const btn = document.getElementById('btn-confirm-promote');
      const errBox = document.getElementById('promote-error-container');
      if (errBox) errBox.classList.add('hidden');
      btn.disabled = true;
      window.VelaI18n.setElementDescriptor(btn, { key: 'lab.actions.promoting' });

      try {
        const res = await callBridge('lab.promote', { id: cmp.id });
        showToast({ key: 'lab.promote.successToast', params: { count: mems.length } });
        closeModal();
        await refreshDashboard(true, true);
        openLabCompareDrawer(cmp.id);
      } catch (err) {
        if (errBox) {
          errBox.className = 'alert-banner alert-danger';
          errBox.innerHTML = '<span data-i18n="lab.promote.failedPrefix">' + escapeHtml(t('lab.promote.failedPrefix')) + '</span>: ' + escapeHtml(err.message);
          errBox.classList.remove('hidden');
        } else {
          showToast({ key: 'lab.promote.failedToast', params: { error: err.message } }, 'error');
        }
        btn.disabled = false;
        window.VelaI18n.setElementDescriptor(btn, { key: 'lab.actions.confirmPromote' });
      }
    });
  }

  // -------------------------------------------------------------------------
  // 7. INBOX VIEW (Only pending approvals with frozen arguments)
  // -------------------------------------------------------------------------
  function renderInboxView(container) {
    const approvals = (state.dashboard && state.dashboard.approvals) || [];
    const pendingApprovals = approvals.filter(a => {
      const st = (a.state || '').toLowerCase();
      return st === 'pending' || st === 'pending approval' || st === '';
    });

    function parseApprovalArgs(rawArgs) {
      if (rawArgs && typeof rawArgs === 'object') return rawArgs;
      if (typeof rawArgs === 'string') {
        try {
          return JSON.parse(rawArgs);
        } catch {
          return {};
        }
      }
      return {};
    }

    function formatRelativePath(fullPath, basePath) {
      if (typeof fullPath !== 'string' || !fullPath) return null;
      if (typeof basePath === 'string' && basePath) {
        if (fullPath === basePath) return './';
        const normalizedBase = basePath.endsWith('/') ? basePath : basePath + '/';
        if (fullPath.startsWith(normalizedBase)) {
          return fullPath.slice(normalizedBase.length) || './';
        }
      }
      return fullPath;
    }

    function getApprovalSummary(appr) {
      const args = parseApprovalArgs(appr.arguments);
      const projectPath = (typeof appr.project === 'string') ? appr.project : '';
      const projectBasename = projectPath ? (projectPath.split('/').filter(Boolean).pop() || projectPath) : t('inbox.globalScope');

      let targetDisplay = null;
      let commandDisplay = null;
      let previewText = null;

      const rawTargetCandidates = [args.path, args.targetFile, args.file, args.target, args.filePath];
      const rawTarget = rawTargetCandidates.find(t => typeof t === 'string' && t.trim().length > 0) || null;
      if (rawTarget) {
        targetDisplay = formatRelativePath(rawTarget, projectPath);
      }

      let executable = null;
      let rawArgv = null;

      // 1. Lab schema: args.command is an array where first element is executable and rest are argv
      if (Array.isArray(args.command) && args.command.length > 0) {
        executable = (typeof args.command[0] === 'string') ? args.command[0] : String(args.command[0]);
        rawArgv = args.command.slice(1);
      }
      // 2. Automation workflow schema: args.executable is a string, args.args is [String]
      else if (typeof args.executable === 'string') {
        executable = args.executable;
        rawArgv = Array.isArray(args.args) ? args.args :
                  (Array.isArray(args.arguments) ? args.arguments :
                  (Array.isArray(args.argv) ? args.argv : null));
      }
      // 3. Fallback schemas: command / cmd / CommandLine as string
      else {
        const rawCmd = (typeof args.command === 'string') ? args.command :
                       (typeof args.cmd === 'string') ? args.cmd :
                       (typeof args.CommandLine === 'string') ? args.CommandLine : null;
        if (rawCmd !== null) {
          executable = rawCmd;
        }
        rawArgv = Array.isArray(args.args) ? args.args :
                  (Array.isArray(args.arguments) ? args.arguments :
                  (Array.isArray(args.argv) ? args.argv : null));
      }

      if (executable !== null && executable !== undefined) {
        if (rawArgv && rawArgv.length > 0) {
          commandDisplay = `${executable}  [argv: ${JSON.stringify(rawArgv)}]`;
        } else {
          commandDisplay = executable;
        }
      } else if (rawArgv && rawArgv.length > 0) {
        commandDisplay = `[argv: ${JSON.stringify(rawArgv)}]`;
      }

      const rawContent = (typeof args.content === 'string') ? args.content :
                         (typeof args.CodeContent === 'string') ? args.CodeContent :
                         (typeof args.patch === 'string') ? args.patch : null;
      if (rawContent && rawContent.trim()) {
        const lines = rawContent.trim().split('\n').slice(0, 3);
        let preview = lines.join('\n');
        if (preview.length > 180) {
          preview = preview.slice(0, 180) + '...';
        } else if (rawContent.trim().split('\n').length > 3) {
          preview += '\n...';
        }
        previewText = preview;
      }

      const frozenTool = (typeof appr.tool === 'string' && appr.tool.trim()) ? appr.tool.trim() : t('inbox.defaultTool');
      const isFileOp = frozenTool.toLowerCase().includes('file') || frozenTool.toLowerCase().includes('write') || frozenTool.toLowerCase().includes('edit');

      let agentDisplay = null;
      let taskDisplay = null;
      let protectedFilesDisplay = null;
      let outputFilesDisplay = null;

      if (args.agent && typeof args.agent === 'object') {
        agentDisplay = t('inbox.agentDisplay', {
          provider: args.agent.provider || 'codex',
          model: args.agent.model || t('common.notSpecified'),
          effort: args.agent.reasoningEffort || 'high'
        });
      }
      if (typeof args.task === 'string' && args.task.trim()) {
        taskDisplay = args.task.trim();
      }
      if (Array.isArray(args.verificationFiles) && args.verificationFiles.length > 0) {
        protectedFilesDisplay = args.verificationFiles.map(f => typeof f === 'string' ? f : (f.path + (f.hash ? ' (' + f.hash.slice(0, 8) + ')' : ''))).join(', ');
      }
      if (Array.isArray(args.outputFiles) && args.outputFiles.length > 0) {
        outputFilesDisplay = args.outputFiles.join(', ');
      }

      return {
        projectBasename,
        projectPath,
        targetDisplay,
        commandDisplay,
        agentDisplay,
        taskDisplay,
        protectedFilesDisplay,
        outputFilesDisplay,
        previewText,
        isFileOp,
        toolName: frozenTool
      };
    }

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="inbox.title">${t('inbox.title')}</h1>
          <p data-i18n="inbox.subtitle">${t('inbox.subtitle')}</p>
        </div>
      </div>

      ${pendingApprovals.length === 0 ? `
        <div class="empty-state">
          <div class="empty-state-title" data-i18n="inbox.emptyTitle">${t('inbox.emptyTitle')}</div>
          <div class="empty-state-desc" data-i18n="inbox.emptyDesc">${t('inbox.emptyDesc')}</div>
        </div>
      ` : `
        <div style="display: flex; flex-direction: column; gap: 14px;">
          ${pendingApprovals.map(appr => {
            const summary = getApprovalSummary(appr);
            return `
              <div class="card" style="margin-bottom: 0; padding: 16px 18px;">
                <div class="card-header" style="margin-bottom: 8px;">
                  <div>
                    <strong style="font-size: 14px;">${escapeHtml(appr.title || t('inbox.defaultApprTitle'))}</strong>
                    <span class="code-badge" style="margin-left: 6px;">${escapeHtml(summary.toolName)}</span>
                  </div>
                  <span class="status-badge status-amber" data-i18n="inbox.statusPending">${t('inbox.statusPending')}</span>
                </div>

                ${appr.intent || appr.description ? `
                  <div style="font-size: 13px; color: var(--text-main); margin-bottom: 10px; line-height: 1.5;">
                    ${escapeHtml(appr.intent || appr.description)}
                  </div>
                ` : ''}

                <div style="font-size: 12px; color: var(--text-secondary); margin-bottom: 10px; display: flex; flex-direction: column; gap: 4px;">
                  <div><strong data-i18n="inbox.metaProject">${t('inbox.metaProject')}</strong> <span class="font-mono" title="${escapeHtml(summary.projectPath)}">${escapeHtml(summary.projectBasename)}</span></div>
                  ${summary.agentDisplay ? `
                    <div><strong data-i18n="inbox.metaEvalAgent">${t('inbox.metaEvalAgent')}</strong> <code class="code-badge font-mono">${escapeHtml(summary.agentDisplay)}</code></div>
                  ` : ''}
                  ${summary.taskDisplay ? `
                    <div style="margin-top: 2px;"><strong data-i18n="inbox.metaEvalTask">${t('inbox.metaEvalTask')}</strong> <div style="font-size: 11.5px; padding: 4px 6px; background: var(--bg-subtle); border-radius: 4px; margin-top: 2px; white-space: pre-wrap;">${escapeHtml(summary.taskDisplay)}</div></div>
                  ` : ''}
                  ${summary.targetDisplay ? `
                    <div><strong data-i18n="inbox.metaTargetFile">${t('inbox.metaTargetFile')}</strong> <code class="code-badge font-mono">${escapeHtml(summary.targetDisplay)}</code></div>
                  ` : (summary.isFileOp ? `
                    <div><strong data-i18n="inbox.metaTargetFile">${t('inbox.metaTargetFile')}</strong> <span class="text-muted" data-i18n="inbox.noTargetFile">${t('inbox.noTargetFile')}</span></div>
                  ` : '')}
                  ${summary.commandDisplay ? `
                    <div><strong>${summary.agentDisplay ? `<span data-i18n="inbox.metaVerifyCommand">${t('inbox.metaVerifyCommand')}</span>` : `<span data-i18n="inbox.metaExecCommand">${t('inbox.metaExecCommand')}</span>`}</strong> <code class="code-badge font-mono">${escapeHtml(summary.commandDisplay)}</code></div>
                  ` : ''}
                  ${summary.protectedFilesDisplay ? `
                    <div><strong data-i18n="inbox.metaProtectedFiles">${t('inbox.metaProtectedFiles')}</strong> <span class="font-mono" style="font-size: 11px;">${escapeHtml(summary.protectedFilesDisplay)}</span></div>
                  ` : ''}
                  ${summary.outputFilesDisplay ? `
                    <div><strong data-i18n="inbox.metaOutputFiles">${t('inbox.metaOutputFiles')}</strong> <span class="font-mono" style="font-size: 11px;">${escapeHtml(summary.outputFilesDisplay)}</span></div>
                  ` : ''}
                </div>

                ${summary.previewText ? `
                  <div style="margin-bottom: 10px;">
                    <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 3px;" data-i18n="inbox.previewTitle">${t('inbox.previewTitle')}</div>
                    <pre class="code-view" style="font-size: 11px; padding: 6px 8px; max-height: 64px; overflow: hidden; margin: 0; white-space: pre-wrap; word-break: break-all;">${escapeHtml(summary.previewText)}</pre>
                  </div>
                ` : ''}

                <details style="margin-bottom: 14px;">
                  <summary style="font-size: 12px; font-weight: 600; cursor: pointer; color: var(--text-secondary); user-select: none;" data-i18n="inbox.detailsSummary">
                    ${t('inbox.detailsSummary')}
                  </summary>
                  <div style="margin-top: 8px; font-size: 12px; color: var(--text-muted); font-family: var(--font-mono); margin-bottom: 6px;">
                    ${summary.projectPath ? `<span data-i18n="inbox.fullProjectPath" data-i18n-params="${escapeHtml(JSON.stringify({ path: summary.projectPath }))}">${t('inbox.fullProjectPath', { path: escapeHtml(summary.projectPath) })}</span><br>` : ''}
                    <span data-i18n="inbox.snapshotHash" data-i18n-params="${escapeHtml(JSON.stringify({ hash: appr.snapshotHash || t('common.none') }))}">${t('inbox.snapshotHash', { hash: appr.snapshotHash ? escapeHtml(appr.snapshotHash) : t('common.none') })}</span>
                  </div>
                  <div class="code-view" style="font-size: 12px; max-height: 160px; overflow-y: auto;">${escapeHtml(typeof appr.arguments === 'object' ? JSON.stringify(appr.arguments, null, 2) : appr.arguments || '{}')}</div>
                </details>

                <div style="display: flex; justify-content: flex-end; gap: 8px;">
                  <button class="btn btn-secondary btn-sm btn-reject-appr" data-id="${escapeHtml(appr.id)}" data-hash="${escapeHtml(appr.snapshotHash || '')}" data-i18n="inbox.btnReject">${t('inbox.btnReject')}</button>
                  <button class="btn btn-primary btn-sm btn-approve-appr" data-id="${escapeHtml(appr.id)}" data-hash="${escapeHtml(appr.snapshotHash || '')}" data-i18n="inbox.btnApprove">${t('inbox.btnApprove')}</button>
                </div>
              </div>
            `;
          }).join('')}
        </div>
      `}
    `;

    container.querySelectorAll('.btn-approve-appr').forEach(btn => {
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        const card = btn.closest('.card');
        if (card) {
          card.querySelectorAll('button').forEach(b => b.disabled = true);
        }
        const id = btn.getAttribute('data-id');
        const snapshotHash = btn.getAttribute('data-hash');
        try {
          await callBridge('approvals.decide', {
            id,
            decision: 'approve',
            snapshotHash
          });
          showToast({ key: 'inbox.approvedToast' });
          await refreshDashboard(true, true);
        } catch (err) {
          showToast({ key: 'inbox.approveFailedToast', params: { error: err.message } }, 'error');
          if (card) {
            card.querySelectorAll('button').forEach(b => b.disabled = false);
          }
        }
      });
    });

    container.querySelectorAll('.btn-reject-appr').forEach(btn => {
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        const card = btn.closest('.card');
        if (card) {
          card.querySelectorAll('button').forEach(b => b.disabled = true);
        }
        const id = btn.getAttribute('data-id');
        const snapshotHash = btn.getAttribute('data-hash');
        try {
          await callBridge('approvals.decide', {
            id,
            decision: 'reject',
            snapshotHash
          });
          showToast({ key: 'inbox.rejectedToast' });
          await refreshDashboard(true, true);
        } catch (err) {
          showToast({ key: 'inbox.rejectFailedToast', params: { error: err.message } }, 'error');
          if (card) {
            card.querySelectorAll('button').forEach(b => b.disabled = false);
          }
        }
      });
    });
  }

  // -------------------------------------------------------------------------
  // 8. SETTINGS VIEW
  // -------------------------------------------------------------------------
  async function renderSettingsView(container) {
    const thisGen = renderGeneration;
    const thisPage = state.currentPage;

    let settings = state.rawSettings || {};
    try {
      const s = await callBridge('settings.get');
      if (s) settings = s;
    } catch {}

    if (thisGen !== renderGeneration || state.currentPage !== thisPage || !document.contains(container)) return;

    // Merge in-progress user draft so background polls or label clicks don't revert inputs
    if (state.settingsDraft) {
      settings = Object.assign({}, settings, state.settingsDraft);
    }

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1 data-i18n="settings.title">${t('settings.title')}</h1>
          <p data-i18n="settings.subtitle">${t('settings.subtitle')}</p>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <span class="card-title" data-i18n="settings.languageTitle">${t('settings.languageTitle')}</span>
        </div>
        <div style="display: flex; align-items: center; justify-content: space-between; gap: 12px; flex-wrap: wrap;">
          <div>
            <strong style="font-size: 13px;" data-i18n="settings.languageSelectLabel">${t('settings.languageSelectLabel')}</strong>
            <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;" data-i18n="settings.languageSelectDesc">${t('settings.languageSelectDesc')}</div>
          </div>
          <select id="setting-locale" class="filter-select" aria-label="界面语言" data-i18n-aria-label="settings.languageAria">
            <option value="zh-CN">简体中文</option>
            <option value="en">English</option>
          </select>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title" data-i18n="settings.notificationsTitle">${t('settings.notificationsTitle')}</span>
          ${(state.systemInfo && state.systemInfo.notificationsSupported === false) ? `<span class="status-badge status-neutral" data-i18n="settings.notificationsSupportedAppOnly">${t('settings.notificationsSupportedAppOnly')}</span>` : ''}
        </div>

        <div style="display: flex; flex-direction: column; gap: 14px;">
          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-notifications" ${settings.notifications ? 'checked' : ''}>
            <div>
              <strong style="font-size: 13px;" data-i18n="settings.desktopNotifications">${t('settings.desktopNotifications')}</strong>
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;" data-i18n="settings.desktopNotificationsDesc">${t('settings.desktopNotificationsDesc')}</div>
            </div>
          </label>

          <fieldset id="sub-notifications-group" ${settings.notifications ? '' : 'disabled'} style="border: none; margin: 0; padding: 0 0 0 24px; display: flex; flex-direction: column; gap: 10px; ${settings.notifications ? '' : 'opacity: 0.5;'}">
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notif-sound" ${settings.notificationSound !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;" data-i18n="settings.sound">${t('settings.sound')}</span>
                <div style="font-size: 12px; color: var(--text-secondary);" data-i18n="settings.soundDesc">${t('settings.soundDesc')}</div>
              </div>
            </label>
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notify-approvals" ${settings.notifyApprovals !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;" data-i18n="settings.approvals">${t('settings.approvals')}</span>
                <div style="font-size: 12px; color: var(--text-secondary);" data-i18n="settings.approvalsDesc">${t('settings.approvalsDesc')}</div>
              </div>
            </label>
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notify-completed" ${settings.notifyCompleted !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;" data-i18n="settings.completed">${t('settings.completed')}</span>
                <div style="font-size: 12px; color: var(--text-secondary);" data-i18n="settings.completedDesc">${t('settings.completedDesc')}</div>
              </div>
            </label>
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notify-errors" ${settings.notifyErrors !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;" data-i18n="settings.errors">${t('settings.errors')}</span>
                <div style="font-size: 12px; color: var(--text-secondary);" data-i18n="settings.errorsDesc">${t('settings.errorsDesc')}</div>
              </div>
            </label>
          </fieldset>

          <div class="sound-preview-bar" style="padding-top: 12px; border-top: 1px solid var(--border-color); display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap;">
            <div>
              <strong style="font-size: 13px;" data-i18n="settings.soundPreview">${t('settings.soundPreview')}</strong>
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;" data-i18n="settings.soundPreviewDesc">${t('settings.soundPreviewDesc')}</div>
            </div>
            <div style="display: flex; align-items: center; gap: 8px;">
              <select id="setting-preview-sound-kind" class="filter-select" aria-label="试听音效事件类型" data-i18n-aria-label="settings.previewSoundAria">
                <option value="approval" data-i18n="settings.soundKindApproval">${t('settings.soundKindApproval')}</option>
                <option value="completed" data-i18n="settings.soundKindCompleted">${t('settings.soundKindCompleted')}</option>
                <option value="error" data-i18n="settings.soundKindError">${t('settings.soundKindError')}</option>
              </select>
              <button id="btn-preview-notification-sound" class="btn btn-secondary btn-sm" data-i18n="settings.btnPreviewSound">${t('settings.btnPreviewSound')}</button>
            </div>
          </div>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title" data-i18n="settings.backgroundTitle">${t('settings.backgroundTitle')}</span>
        </div>
        <div style="display: flex; flex-direction: column; gap: 14px;">
          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-launch-at-login" ${settings.launchAtLogin ? 'checked' : ''}>
            <div>
              <strong style="font-size: 13px;" data-i18n="settings.launchAtLogin">${t('settings.launchAtLogin')}</strong>
              ${(state.systemInfo && (state.systemInfo.launchAtLoginStatus === 'pending_approval' || state.systemInfo.launchAtLoginStatus === 'requiresApproval')) ? `<span class="status-badge status-amber" style="margin-left: 6px;" data-i18n="settings.launchPendingApproval">${t('settings.launchPendingApproval')}</span>` : ''}
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;" data-i18n="settings.launchAtLoginDesc">${t('settings.launchAtLoginDesc')}</div>
            </div>
          </label>

          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-analysis" ${settings.analysisEnabled ? 'checked' : ''}>
            <div>
              <strong style="font-size: 13px;" data-i18n="settings.analysis">${t('settings.analysis')}</strong>
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;" data-i18n="settings.analysisDesc">${t('settings.analysisDesc')}</div>
            </div>
          </label>
        </div>

        <div style="margin-top: 16px; padding-top: 14px; border-top: 1px solid var(--border-color); display: flex; justify-content: flex-end;">
          <button id="btn-save-settings" class="btn btn-primary btn-sm" data-i18n="settings.btnSave">${t('settings.btnSave')}</button>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title" data-i18n="settings.privacyTitle">${t('settings.privacyTitle')}</span>
          <span class="status-badge status-sage" data-i18n="settings.noTelemetry">${t('settings.noTelemetry')}</span>
        </div>
        <ul style="padding-left: 18px; font-size: 12px; line-height: 1.6; color: var(--text-secondary);">
          <li><strong data-i18n="settings.currentStorePath">${t('settings.currentStorePath')}</strong><code class="code-badge">${escapeHtml(state.systemInfo.home)}</code> (Channel: ${escapeHtml(state.systemInfo.channel)})</li>
          <li><strong data-i18n="settings.noCloudAccount">${t('settings.noCloudAccount')}</strong><span data-i18n="settings.noCloudAccountDesc">${t('settings.noCloudAccountDesc')}</span></li>
          <li><strong data-i18n="settings.localFirst">${t('settings.localFirst')}</strong><span data-i18n="settings.localFirstDesc">${t('settings.localFirstDesc')}</span></li>
          <li><strong data-i18n="settings.disableTelemetry">${t('settings.disableTelemetry')}</strong><span data-i18n="settings.disableTelemetryDesc">${t('settings.disableTelemetryDesc')}</span></li>
          <li><strong data-i18n="settings.privacyIsolation">${t('settings.privacyIsolation')}</strong><span data-i18n="settings.privacyIsolationDesc">${t('settings.privacyIsolationDesc')}</span></li>
        </ul>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title" data-i18n="settings.integrationTitle">${t('settings.integrationTitle')}</span>
        </div>
        <div style="font-size: 12px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
          <div>Claude Desktop: <span class="status-badge status-neutral" data-i18n="settings.supportedStdioMcp">${t('settings.supportedStdioMcp')}</span></div>
          <div>Cursor: <span class="status-badge status-neutral" data-i18n="settings.supportedStdioMcp">${t('settings.supportedStdioMcp')}</span></div>
          <div>Codex: <span class="status-badge status-neutral" data-i18n="settings.supportedCheckpointExport">${t('settings.supportedCheckpointExport')}</span></div>
          <div><span data-i18n="settings.autoCloudSync">${t('settings.autoCloudSync')}</span><span class="status-badge status-neutral" data-i18n="settings.notSupportedCloudSync">${t('settings.notSupportedCloudSync')}</span></div>
        </div>
      </div>
    `;

    const notifCb = document.getElementById('setting-notifications');
    const soundCb = document.getElementById('setting-notif-sound');
    const apprvCb = document.getElementById('setting-notify-approvals');
    const compCb = document.getElementById('setting-notify-completed');
    const errCb = document.getElementById('setting-notify-errors');
    const loginCb = document.getElementById('setting-launch-at-login');
    const analysisCb = document.getElementById('setting-analysis');
    const subGroup = document.getElementById('sub-notifications-group');

    const updateDraft = () => {
      const notifEnabled = Boolean(notifCb && notifCb.checked);
      if (subGroup) {
        subGroup.disabled = !notifEnabled;
        subGroup.style.opacity = notifEnabled ? '1' : '0.5';
        subGroup.querySelectorAll('input').forEach(inp => inp.disabled = !notifEnabled);
      }
      state.settingsDraft = {
        notifications: notifEnabled,
        notificationSound: Boolean(soundCb && soundCb.checked),
        notifyApprovals: Boolean(apprvCb && apprvCb.checked),
        notifyCompleted: Boolean(compCb && compCb.checked),
        notifyErrors: Boolean(errCb && errCb.checked),
        launchAtLogin: Boolean(loginCb && loginCb.checked),
        analysisEnabled: Boolean(analysisCb && analysisCb.checked)
      };
    };

    if (subGroup && !settings.notifications) {
      subGroup.querySelectorAll('input').forEach(inp => inp.disabled = true);
    }

    document.getElementById('btn-preview-notification-sound')?.addEventListener('click', async () => {
      const select = document.getElementById('setting-preview-sound-kind');
      const kind = (select && select.value) || 'approval';
      if (!['approval', 'completed', 'error'].includes(kind)) {
        showToast({ key: 'settings.invalidSoundKind' }, 'error');
        return;
      }
      const btn = document.getElementById('btn-preview-notification-sound');
      if (btn) btn.disabled = true;
      try {
        await callBridge('system.previewNotificationSound', { kind });
        const kindLabel = kind === 'approval' ? t('settings.previewKindApproval') : kind === 'completed' ? t('settings.previewKindCompleted') : t('settings.previewKindError');
        showToast({ key: 'settings.soundPreviewPlayed', params: { kind: kindLabel } });
      } catch (err) {
        const defErr = t('settings.soundPreviewDefaultError');
        showToast({ key: 'settings.soundPreviewFailed', params: { error: err.message || t('settings.soundPreviewDefaultError') } }, 'error');
      } finally {
        if (btn) btn.disabled = false;
      }
    });
    const localeSelect = document.getElementById('setting-locale');
    if (localeSelect) {
      const persistedLoc = (settings && (settings.locale === 'en' || settings.locale === 'zh-CN')) ? settings.locale : (window.VelaI18n ? window.VelaI18n.getLocale() : 'zh-CN');
      localeSelect.value = persistedLoc;
      localeSelect.addEventListener('change', async () => {
        const selectedLocale = localeSelect.value;
        if (selectedLocale !== 'zh-CN' && selectedLocale !== 'en') return;
        const previousLocale = window.VelaI18n ? window.VelaI18n.getLocale() : 'zh-CN';
        localeSelect.disabled = true;
        try {
          const res = await callBridge('settings.save', { locale: selectedLocale });
          const confirmed = (res && res.locale) ? res.locale : selectedLocale;
          state.rawSettings = Object.assign({}, state.rawSettings, { locale: confirmed });
          if (window.VelaI18n) {
            window.VelaI18n.setLocale(confirmed);
          }
          showToast({ key: 'settings.localeSaved' });
        } catch (err) {
          localeSelect.value = previousLocale;
          const errorPrefix = t('settings.saveLocaleFailed');
          showToast(`${errorPrefix}: ${err.message || String(err)}`, 'error');
        } finally {
          localeSelect.disabled = false;
        }
      });
    }

    notifCb?.addEventListener('change', updateDraft);
    soundCb?.addEventListener('change', updateDraft);
    apprvCb?.addEventListener('change', updateDraft);
    compCb?.addEventListener('change', updateDraft);
    errCb?.addEventListener('change', updateDraft);
    loginCb?.addEventListener('change', updateDraft);
    analysisCb?.addEventListener('change', updateDraft);

    document.getElementById('btn-save-settings').addEventListener('click', async () => {
      const payload = {
        notifications: Boolean(notifCb && notifCb.checked),
        notificationSound: Boolean(soundCb && soundCb.checked),
        notifyApprovals: Boolean(apprvCb && apprvCb.checked),
        notifyCompleted: Boolean(compCb && compCb.checked),
        notifyErrors: Boolean(errCb && errCb.checked),
        launchAtLogin: Boolean(loginCb && loginCb.checked),
        analysisEnabled: Boolean(analysisCb && analysisCb.checked)
      };

      try {
        await callBridge('settings.save', payload);
        state.settingsDraft = null;
        showToast({ key: 'settings.saved' });
        await refreshDashboard(true, true);
      } catch (err) {
        showToast({ key: 'settings.saveFailed', params: { error: err.message || '' } }, 'error');
      }
    });
  }

  // -------------------------------------------------------------------------
  // GLOBAL MODALS (Cmd-K Search, Checkpoints)
  // -------------------------------------------------------------------------
  function openSearchModal() {
    const originalActive = document.activeElement;
    const modalBody = `
      <div class="form-group">
        <input type="search" id="global-search-input" class="form-input" placeholder="${escapeHtml(t('search.placeholder'))}" data-i18n-placeholder="search.placeholder" autofocus>
      </div>
      <div style="display: flex; align-items: center; justify-content: space-between; font-size: 11px;">
        <label class="form-checkbox-label">
          <input type="checkbox" id="search-include-private">
          <span data-i18n="search.includePrivate">${escapeHtml(t('search.includePrivate'))}</span>
        </label>
        <span class="text-secondary" data-i18n="search.escHint">${escapeHtml(t('search.escHint'))}</span>
      </div>
      <div id="search-results-list" style="margin-top: 10px; max-height: 280px; overflow-y: auto;">
        <div class="text-secondary" data-i18n="search.enterPrompt" style="font-size: 11px; padding: 12px 0; text-align: center;">${escapeHtml(t('search.enterPrompt'))}</div>
      </div>
    `;

    openModal({ key: 'search.title' }, modalBody, '');

    const input = document.getElementById('global-search-input');
    const chkPrivate = document.getElementById('search-include-private');
    const resultsList = document.getElementById('search-results-list');

    const doSearch = async () => {
      const query = input.value.trim();
      if (!query) return;
      resultsList.innerHTML = `<div class="text-secondary" data-i18n="search.searching" style="font-size: 11px; padding: 10px 0;">${escapeHtml(t('search.searching'))}</div>`;

      try {
        const results = await callBridge('search', {
          query,
          project: state.currentProject || undefined,
          includePrivate: chkPrivate.checked
        });

        const items = Array.isArray(results) ? results : [];
        if (items.length === 0) {
          resultsList.innerHTML = `<div data-i18n="search.noMatch" style="font-size: 11px; color: var(--text-muted); padding: 16px 0; text-align: center;">${escapeHtml(t('search.noMatch'))}</div>`;
          return;
        }

        resultsList.innerHTML = `
          <div style="display: flex; flex-direction: column; gap: 6px;">
            ${items.map((item, idx) => `
              <div class="card clickable-card search-result-card" tabindex="0" role="button" data-index="${idx}" style="padding: 10px 12px; margin-bottom: 0; cursor: pointer; text-align: left; border: 1px solid var(--border-color); border-radius: 6px; background: var(--bg-card);">
                <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 4px;">
                  <strong style="font-size: 13px; color: var(--text-primary);">${escapeHtml(item.title || item.id)}</strong>
                  <span class="code-badge">${escapeHtml(item.kind || 'evidence')}</span>
                </div>
                <div style="font-size: 12px; color: var(--text-secondary); line-height: 1.5; word-break: break-word;">${escapeHtml(item.content || item.description || '')}</div>
                ${item.project ? `<div style="font-size: 12px; color: var(--text-muted); margin-top: 4px; font-family: var(--font-mono);">${escapeHtml(item.project)}</div>` : ''}
              </div>
            `).join('')}
          </div>
        `;

        const handleItemSelect = (item) => {
          closeModal();
          if (item.kind === 'session' || item.sessionId) {
            openSessionDetail(item.id || item.sessionId);
          } else if (item.kind === 'run' || item.runId) {
            openRunDetail(item.id || item.runId);
          } else if (item.kind === 'suggestion') {
            openImprovePreviewDrawer(item.id);
          } else if (item.kind === 'lab' || item.kind === 'evaluation') {
            openLabCompareDrawer(item.id);
          } else {
            // Open full detail in drawer with uncropped content and evidence
            openDrawer(item.title || item.id, item.kind ? { key: 'search.evidenceKind', params: { kind: item.kind } } : { key: 'search.evidenceDetail' });
            const drawerBody = document.getElementById('drawer-content');
            if (drawerBody) {
              drawerBody.innerHTML = `
                <div style="display: flex; flex-direction: column; gap: 12px;">
                  <div class="card">
                    <div class="card-header">
                      <span class="card-title">${escapeHtml(item.title || item.id)}</span>
                      <span class="code-badge">${escapeHtml(item.kind || 'evidence')}</span>
                    </div>
                    <div style="font-size: 13px; line-height: 1.6; white-space: pre-wrap; word-break: break-word; color: var(--text-primary);">
                      ${escapeHtml(item.content || item.description || t('search.noDetailedText'))}
                    </div>
                  </div>
                  ${item.project ? `
                    <div class="card" style="font-size: 12px;">
                      <div class="text-secondary" data-i18n="search.projectPath" style="margin-bottom: 4px;">${escapeHtml(t('search.projectPath'))}</div>
                      <code class="code-badge">${escapeHtml(item.project)}</code>
                    </div>
                  ` : ''}
                  ${item.sourceFile ? `
                    <div class="card" style="font-size: 12px;">
                      <div class="text-secondary" data-i18n="search.sourceFile" style="margin-bottom: 4px;">${escapeHtml(t('search.sourceFile'))}</div>
                      <code class="code-badge">${escapeHtml(item.sourceFile)}</code>
                    </div>
                  ` : ''}
                  ${item.metadata ? `
                    <div class="card">
                      <div class="card-header"><span class="card-title" data-i18n="search.metadata">${escapeHtml(t('search.metadata'))}</span></div>
                      <div class="code-view" style="font-size: 12px;">${escapeHtml(typeof item.metadata === 'object' ? JSON.stringify(item.metadata, null, 2) : String(item.metadata))}</div>
                    </div>
                  ` : ''}
                </div>
              `;
            }
          }
        };

        resultsList.querySelectorAll('.search-result-card').forEach(card => {
          const idx = parseInt(card.getAttribute('data-index'), 10);
          const item = items[idx];
          if (!item) return;
          card.addEventListener('click', () => handleItemSelect(item));
          card.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              handleItemSelect(item);
            }
          });
        });
      } catch (err) {
        resultsList.innerHTML = `<div class="alert-banner alert-danger">${escapeHtml(err.message)}</div>`;
      }
    };

    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') doSearch();
    });
    chkPrivate.addEventListener('change', () => {
      if (input.value.trim()) doSearch();
    });

    const thisSearchModalInstance = currentModalInstance;
    setTimeout(() => {
      if (currentModalInstance !== thisSearchModalInstance) return;
      const modal = document.getElementById('modal-container');
      if (!modal || modal.classList.contains('hidden')) return;
      const active = document.activeElement;
      if (active && active !== originalActive && active !== document.body && active !== document.documentElement) {
        return;
      }
      input.focus();
    }, 20);
  }

  function openSaveCheckpointModal(session) {
    const defaultTitle = session.title
      ? t('checkpoint.defaultTitleSummary', { title: session.title })
      : t('checkpoint.defaultTitleFallback');

    const modalBody = `
      <div class="form-group">
        <label class="form-label" data-i18n="checkpoint.titleLabel">${escapeHtml(t('checkpoint.titleLabel'))}</label>
        <input type="text" id="cp-title" class="form-input" value="${escapeHtml(defaultTitle)}" data-i18n-placeholder="checkpoint.titlePlaceholder" placeholder="${escapeHtml(t('checkpoint.titlePlaceholder'))}">
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="checkpoint.goalLabel">${escapeHtml(t('checkpoint.goalLabel'))}</label>
        <input type="text" id="cp-goal" class="form-input" data-i18n-placeholder="checkpoint.goalPlaceholder" placeholder="${escapeHtml(t('checkpoint.goalPlaceholder'))}">
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="checkpoint.completedLabel">${escapeHtml(t('checkpoint.completedLabel'))}</label>
        <textarea id="cp-completed" class="form-textarea" data-i18n-placeholder="checkpoint.completedPlaceholder" placeholder="${escapeHtml(t('checkpoint.completedPlaceholder'))}"></textarea>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="checkpoint.pendingLabel">${escapeHtml(t('checkpoint.pendingLabel'))}</label>
        <textarea id="cp-pending" class="form-textarea" data-i18n-placeholder="checkpoint.pendingPlaceholder" placeholder="${escapeHtml(t('checkpoint.pendingPlaceholder'))}"></textarea>
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="checkpoint.testsLabel">${escapeHtml(t('checkpoint.testsLabel'))}</label>
        <input type="text" id="cp-tests" class="form-input" data-i18n-placeholder="checkpoint.testsPlaceholder" placeholder="${escapeHtml(t('checkpoint.testsPlaceholder'))}">
      </div>
      <div class="form-group">
        <label class="form-label" data-i18n="checkpoint.nextLabel">${escapeHtml(t('checkpoint.nextLabel'))}</label>
        <input type="text" id="cp-next" class="form-input" data-i18n-placeholder="checkpoint.nextPlaceholder" placeholder="${escapeHtml(t('checkpoint.nextPlaceholder'))}">
      </div>
    `;

    openModal({ key: 'checkpoint.saveModalTitle' }, modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-cp" data-i18n="common.cancel">${escapeHtml(t('common.cancel'))}</button>
      <button class="btn btn-primary" id="btn-save-cp" data-i18n="sessions.btnSaveCheckpoint">${escapeHtml(t('sessions.btnSaveCheckpoint'))}</button>
    `);

    document.getElementById('btn-cancel-cp').addEventListener('click', closeModal);
    document.getElementById('btn-save-cp').addEventListener('click', async () => {
      const title = document.getElementById('cp-title').value.trim();
      const goal = document.getElementById('cp-goal').value.trim();
      const completed = document.getElementById('cp-completed').value.trim();
      const pending = document.getElementById('cp-pending').value.trim();
      const tests = document.getElementById('cp-tests').value.trim();
      const nextActions = document.getElementById('cp-next').value.trim();

      if (!goal) {
        showToast({ key: 'checkpoint.goalRequired' }, 'error');
        return;
      }

      try {
        const cp = await callBridge('checkpoint.save', {
          sessionId: session.id,
          project: session.project,
          title,
          goal,
          completed,
          pending,
          tests,
          nextActions
        });

        showToast({ key: 'checkpoint.saveSuccess' });
        closeModal();

        if (cp && cp.id) {
          openExportCheckpointModal(cp.id);
        }
      } catch (err) {
        showToast({ key: 'checkpoint.saveFailed', params: { error: err.message } }, 'error');
      }
    });
  }

  async function openExportCheckpointModal(checkpointId) {
    let currentProvider = 'Claude';

    const renderExportBody = async () => {
      const exp = await callBridge('checkpoint.export', { id: checkpointId, provider: currentProvider });
      return `
        <div class="form-group">
          <label class="form-label" data-i18n="checkpoint.targetProviderLabel">${escapeHtml(t('checkpoint.targetProviderLabel'))}</label>
          <select id="cp-exp-prov" class="filter-select">
            <option value="Claude" ${currentProvider === 'Claude' ? 'selected' : ''}>Claude</option>
            <option value="Codex" ${currentProvider === 'Codex' ? 'selected' : ''}>Codex</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="checkpoint.handoverPathLabel">${escapeHtml(t('checkpoint.handoverPathLabel'))}</label>
          <input type="text" class="form-input font-mono" readonly value="${escapeHtml(exp ? exp.path || '' : '')}">
        </div>
        <div class="form-group">
          <label class="form-label">
            <span data-i18n="checkpoint.launchCmdLabel">${escapeHtml(t('checkpoint.launchCmdLabel'))}</span>
            <button class="btn btn-ghost btn-sm" id="btn-copy-cp-cmd" data-i18n="checkpoint.btnCopyCmd">${escapeHtml(t('checkpoint.btnCopyCmd'))}</button>
          </label>
          <input type="text" id="cp-exp-cmd" class="form-input font-mono" readonly value="${escapeHtml(exp ? exp.command || '' : '')}">
        </div>
        <div class="form-group">
          <label class="form-label" data-i18n="checkpoint.previewLabel">${escapeHtml(t('checkpoint.previewLabel'))}</label>
          <div class="code-view" style="max-height: 140px;">${escapeHtml(exp ? exp.content || '' : '')}</div>
        </div>
      `;
    };

    openModal({ key: 'checkpoint.exportModalTitle' }, await renderExportBody(), `
      <button class="btn btn-primary" id="btn-close-cp-exp" data-i18n="checkpoint.btnFinish">${escapeHtml(t('checkpoint.btnFinish'))}</button>
    `);

    const bindHandlers = () => {
      const provSel = document.getElementById('cp-exp-prov');
      if (provSel) {
        provSel.addEventListener('change', async (e) => {
          currentProvider = e.target.value;
          const body = await renderExportBody();
          document.getElementById('modal-body').innerHTML = body;
          bindHandlers();
        });
      }
      const copyBtn = document.getElementById('btn-copy-cp-cmd');
      if (copyBtn) {
        copyBtn.addEventListener('click', () => {
          const cmd = document.getElementById('cp-exp-cmd').value;
          navigator.clipboard.writeText(cmd).then(() => {
            showToast({ key: 'checkpoint.copiedCmd' });
          });
        });
      }
      const closeBtn = document.getElementById('btn-close-cp-exp');
      if (closeBtn) closeBtn.addEventListener('click', closeModal);
    };

    bindHandlers();
  }

  // -------------------------------------------------------------------------
  // DRAWER & MODAL HELPERS WITH FOCUS TRAP AND RESTORATION
  // -------------------------------------------------------------------------
  let modalTriggerElement = null;
  let modalTrapHandler = null;
  let drawerTriggerElement = null;
  let drawerTrapHandler = null;
  let modalInstanceCounter = 0;
  let currentModalInstance = 0;
  let drawerInstanceCounter = 0;
  let currentDrawerInstance = 0;

  function trapFocus(container, e) {
    if (e.key !== 'Tab') return;
    const focusables = Array.from(container.querySelectorAll(
      'button:not([disabled]):not([aria-hidden="true"]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )).filter(el => (el.offsetWidth > 0 || el.offsetHeight > 0 || el.getClientRects().length > 0));

    if (focusables.length === 0) {
      e.preventDefault();
      return;
    }

    const first = focusables[0];
    const last = focusables[focusables.length - 1];

    if (!container.contains(document.activeElement)) {
      if (e.shiftKey) {
        last.focus();
      } else {
        first.focus();
      }
      e.preventDefault();
      return;
    }

    if (e.shiftKey) {
      if (document.activeElement === first) {
        last.focus();
        e.preventDefault();
      }
    } else {
      if (document.activeElement === last) {
        first.focus();
        e.preventDefault();
      }
    }
  }

  function openDrawer(title = '', subtitle = '', triggerEl = null) {
    const thisDrawerInstance = ++drawerInstanceCounter;
    currentDrawerInstance = thisDrawerInstance;
    const originalActive = document.activeElement;
    const validTrigger = (triggerEl && typeof triggerEl === 'object' && triggerEl.nodeType === 1) ? triggerEl : null;
    drawerTriggerElement = validTrigger || originalActive;
    const drawer = document.getElementById('detail-drawer');
    const backdrop = document.getElementById('drawer-backdrop');
    const titleEl = document.getElementById('drawer-title');
    const s = document.getElementById('drawer-subtitle');
    const content = document.getElementById('drawer-content');
    const customActions = document.getElementById('drawer-custom-actions');

    if (titleEl) setElementDescriptor(titleEl, title || { key: 'shell.drawerTitle' });
    if (s) setElementDescriptor(s, subtitle);
    if (customActions) customActions.innerHTML = '';
    if (content) content.innerHTML = `<div class="empty-state"><div class="empty-state-title" data-i18n="common.loading">${escapeHtml(t('common.loading'))}</div></div>`;

    if (drawer) drawer.classList.remove('hidden');

    const isWide = window.innerWidth >= 1150;
    document.body.classList.toggle('has-inspector-open', isWide);

    if (backdrop) {
      backdrop.classList.toggle('hidden', isWide);
    }

    if (drawerTrapHandler) {
      document.removeEventListener('keydown', drawerTrapHandler, true);
      drawerTrapHandler = null;
    }

    // Only trap focus in drawer if in narrow modal overlay mode (<1150px)
    if (!isWide) {
      drawerTrapHandler = function(e) {
        const modal = document.getElementById('modal-container');
        const isModalOpen = modal && !modal.classList.contains('hidden');
        if (!isModalOpen && drawer && !drawer.classList.contains('hidden')) {
          trapFocus(drawer, e);
        }
      };
      document.addEventListener('keydown', drawerTrapHandler, true);
    }

    setTimeout(() => {
      if (currentDrawerInstance !== thisDrawerInstance) return;
      const modal = document.getElementById('modal-container');
      if (modal && !modal.classList.contains('hidden')) return;

      const currentDrawer = document.getElementById('detail-drawer');
      if (!currentDrawer || currentDrawer.classList.contains('hidden')) return;

      const active = document.activeElement;
      if (active && active !== originalActive && active !== document.body && active !== document.documentElement) {
        return;
      }

      const closeBtn = document.getElementById('btn-close-drawer');
      const firstFocusable = currentDrawer.querySelector('button:not([disabled]):not(#btn-close-drawer), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex="0"]');
      if (firstFocusable) {
        firstFocusable.focus();
      } else if (closeBtn) {
        closeBtn.focus();
      }
    }, 20);
  }

  function setDrawerTitle(title, subtitle = '') {
    const titleEl = document.getElementById('drawer-title');
    const s = document.getElementById('drawer-subtitle');
    if (titleEl) setElementDescriptor(titleEl, title);
    if (s) setElementDescriptor(s, subtitle);
  }

  function setDrawerCustomActions(html) {
    const act = document.getElementById('drawer-custom-actions');
    if (act) act.innerHTML = html;
  }

  function closeDrawer() {
    currentDrawerInstance = ++drawerInstanceCounter;
    const drawer = document.getElementById('detail-drawer');
    const backdrop = document.getElementById('drawer-backdrop');
    if (drawer) drawer.classList.add('hidden');
    if (backdrop) backdrop.classList.add('hidden');
    document.body.classList.remove('has-inspector-open');
    state.selectedSessionId = null;
    state.selectedRunId = null;
    state.selectedSuggestionId = null;
    state.selectedEvalId = null;
    sessionDetailSequence++;
    state.loadedSessionDetail = null;

    if (drawerTrapHandler) {
      document.removeEventListener('keydown', drawerTrapHandler, true);
      drawerTrapHandler = null;
    }

    if (drawerTriggerElement && typeof drawerTriggerElement.focus === 'function') {
      try {
        drawerTriggerElement.focus();
      } catch {}
    }
    drawerTriggerElement = null;

    if (state.hasPendingSnapshot) {
      refreshDashboard(false, false);
    }
  }

  function openModal(title, bodyHtml, footerHtml = '', triggerEl = null) {
    const thisModalInstance = ++modalInstanceCounter;
    currentModalInstance = thisModalInstance;
    const originalActive = document.activeElement;
    const validTrigger = (triggerEl && typeof triggerEl === 'object' && triggerEl.nodeType === 1) ? triggerEl : null;
    modalTriggerElement = validTrigger || originalActive;
    const modal = document.getElementById('modal-container');
    const dialog = document.getElementById('modal-dialog');
    const t = document.getElementById('modal-title');
    const b = document.getElementById('modal-body');
    const f = document.getElementById('modal-footer');
    if (t) setElementDescriptor(t, title || { key: 'shell.modalTitle' });
    if (b) b.innerHTML = bodyHtml;
    if (f) {
      f.innerHTML = footerHtml;
      if (!footerHtml) f.classList.add('hidden');
      else f.classList.remove('hidden');
    }
    if (modal) modal.classList.remove('hidden');

    if (modalTrapHandler) {
      document.removeEventListener('keydown', modalTrapHandler, true);
      modalTrapHandler = null;
    }

    modalTrapHandler = function(e) {
      if (modal && !modal.classList.contains('hidden')) {
        trapFocus(dialog || modal, e);
      }
    };
    document.addEventListener('keydown', modalTrapHandler, true);

    setTimeout(() => {
      if (currentModalInstance !== thisModalInstance) return;
      if (!modal || modal.classList.contains('hidden')) return;

      const active = document.activeElement;
      if (active && active !== originalActive && active !== document.body && active !== document.documentElement) {
        return;
      }

      const firstInput = modal.querySelector('input:not([disabled]), textarea:not([disabled]), select:not([disabled]), button:not([disabled]):not(#btn-close-modal)');
      if (firstInput) {
        firstInput.focus();
      } else {
        const closeBtn = document.getElementById('btn-close-modal');
        if (closeBtn) closeBtn.focus();
      }
    }, 20);
  }

  function closeModal() {
    currentModalInstance = ++modalInstanceCounter;
    const modal = document.getElementById('modal-container');
    if (modal) modal.classList.add('hidden');

    if (modalTrapHandler) {
      document.removeEventListener('keydown', modalTrapHandler, true);
      modalTrapHandler = null;
    }

    if (modalTriggerElement && typeof modalTriggerElement.focus === 'function') {
      try {
        modalTriggerElement.focus();
      } catch {}
    }
    modalTriggerElement = null;

    if (state.hasPendingSnapshot) {
      refreshDashboard(false, false);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
