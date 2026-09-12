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

  function formatTime(isoStr) {
    if (!isoStr) return '-';
    try {
      const d = new Date(isoStr);
      if (isNaN(d.getTime())) return '-';
      return d.toLocaleString('zh-CN', {
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
    if (num === null || num === undefined || isNaN(num)) return '0';
    return Number(num).toLocaleString();
  }

  function showToast(message, type = 'info') {
    const container = document.getElementById('toast-container');
    if (!container) return;
    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    toast.textContent = message;
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
        textEl.textContent = message;
      } else if (statusState === 'connected') {
        textEl.textContent = '本地服务就绪 · 无云端遥测';
      } else if (statusState === 'loading') {
        textEl.textContent = '正在连接本地服务...';
      } else if (statusState === 'error') {
        textEl.textContent = '本地服务未连接';
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
      updateFooterStatus('error', reason || '本地服务已断开');
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
    updateFooterStatus('loading', '正在连接本地服务...');
    setupShortcuts();
    setupEventListeners();

    if (window.vela && typeof window.vela.call === 'function') {
      state.isBridgeAvailable = true;
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
    container.innerHTML = `
      <div class="empty-state" style="padding-top: 100px;">
        <div class="empty-state-title" style="color: var(--status-red); font-size: 14px;">无法连接 Vela 本地工程服务</div>
        <div class="empty-state-desc" style="font-size: 12px; color: var(--text-secondary); max-width: 440px; margin: 8px auto;">
          ${escapeHtml(err.message || '辅助服务未就绪或未启动。')}
        </div>
        <button id="btn-init-retry" class="btn btn-primary btn-sm" style="margin-top: 14px;">重试连接</button>
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
    const targetLabel = targetProject ? (targetProject.split('/').filter(Boolean).pop() || targetProject) : '全局';
    const errMessage = (state.scopeError && state.scopeError.project === targetProject && state.scopeError.message)
      ? state.scopeError.message
      : '未能拉取该工程数据或本地服务未响应';
    const priorProject = state.scopeError ? state.scopeError.priorProject : (state.priorProject || '');

    container.innerHTML = `
      <div class="empty-state" style="padding: 60px 24px;">
        <div class="empty-state-title" style="color: var(--status-red, #dc2626); font-size: 15px;">
          无法加载工程「${escapeHtml(targetLabel)}」数据
        </div>
        <div class="empty-state-desc" style="font-size: 12px; color: var(--text-secondary); max-width: 480px; margin: 8px auto 16px;">
          ${escapeHtml(errMessage)}。为避免显示其他工程的残留数据，已暂停渲染当前视图。
        </div>
        <div style="display: flex; gap: 10px; justify-content: center; flex-wrap: wrap;">
          <button id="btn-retry-scope" class="btn btn-primary btn-sm">重试加载</button>
          ${priorProject !== undefined && priorProject !== null && priorProject !== targetProject ? `
            <button id="btn-revert-scope" class="btn btn-secondary btn-sm">返回此前工作空间</button>
          ` : `
            <button id="btn-revert-global-scope" class="btn btn-secondary btn-sm">切换至全局视图</button>
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
            updateFooterStatus('connected', state.isDemoMode ? '演示模式 · 离线快照' : '本地服务就绪 · 无云端遥测');
            state.dashboard = result;
            state.dashboardScope = requestedProject;
            state.scopeError = null;
            if (Array.isArray(result.projects)) {
              state.registeredProjects = result.projects;
              updateProjectSelector();
            }
            if (result.settings) {
              state.rawSettings = result.settings;
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
            updateFooterStatus('error', '本地服务未连接');
            if (shouldShowErr) {
              showGlobalError('获取本地数据失败：' + (err.message || '未知错误'));
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
              message: err.message || '未知错误'
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

    sel.innerHTML = '<option value="">所有项目 (全部上下文)</option>';
    for (const proj of projects) {
      const opt = document.createElement('option');
      opt.value = proj.path || proj.id || '';
      opt.textContent = proj.title || proj.name || proj.path || '未命名项目';
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
        showToast('数据已刷新');
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
        <span>收到 <strong>${count}</strong> 条跨模块聚合事件，请选择您要查看的工程分类：</span>
      </div>
      <div style="display: flex; flex-direction: column; gap: 10px;">
        ${hasSessions ? `
          <button class="btn btn-secondary btn-choice-agg" data-target="agents" style="justify-content: flex-start; padding: 10px 14px; text-align: left;">
            <strong style="font-size: 13px;">查看会话</strong>
            <span style="font-size: 12px; color: var(--text-secondary); margin-left: 8px;">智能体交互日志与工具调用</span>
          </button>
        ` : ''}
        ${hasRuns ? `
          <button class="btn btn-secondary btn-choice-agg" data-target="workflows" style="justify-content: flex-start; padding: 10px 14px; text-align: left;">
            <strong style="font-size: 13px;">查看工作流</strong>
            <span style="font-size: 12px; color: var(--text-secondary); margin-left: 8px;">脚本编排与运行记录</span>
          </button>
        ` : ''}
        ${hasApprovals ? `
          <button class="btn btn-secondary btn-choice-agg" data-target="inbox" style="justify-content: flex-start; padding: 10px 14px; text-align: left;">
            <strong style="font-size: 13px;">查看待办审批</strong>
            <span style="font-size: 12px; color: var(--text-secondary); margin-left: 8px;">写操作与关键安全门禁</span>
          </button>
        ` : ''}
      </div>
    `;

    openModal('聚合通知分类选择', modalBody, '<button class="btn btn-secondary btn-sm" id="btn-cancel-agg-modal">关闭</button>');
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
            showToast('已连接项目: ' + selectedDir);
            await refreshDashboard(true, true);
          }
        } catch (err) {
          showToast('添加项目失败: ' + err.message, 'error');
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
          <h1>工程记忆</h1>
          <p>跨会话继承的本地上下文与经验沉淀 · 项目隔离与人工流转</p>
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
          <h1>会话</h1>
          <p>观察智能体会话日志、工具调用与上下文证据 · 共 ${filteredSessions.length} 个会话 (${runningCount} 运行中)</p>
        </div>
        <div class="page-actions">
          <button id="btn-refresh-sessions" class="btn btn-secondary btn-sm">增量刷新</button>
          <button id="btn-add-project-agents" class="btn btn-primary btn-sm">+ 连接项目</button>
        </div>
      </div>

      <div class="toolbar-bar">
        <div class="toolbar-filters">
          <input type="search" id="session-search-input" class="filter-input" placeholder="搜索会话标题、模型或路径..." title="搜索会话标题、模型或路径（点击表格任意行可打开详情与 Checkpoint）" style="width: 240px;" value="${escapeHtml(state.sessionFilterQuery)}">
          <select id="session-provider-filter" class="filter-select">
            <option value="">所有 Provider</option>
            <option value="claude" ${(state.sessionProviderFilter || '').toLowerCase() === 'claude' ? 'selected' : ''}>claude</option>
            <option value="codex" ${(state.sessionProviderFilter || '').toLowerCase() === 'codex' ? 'selected' : ''}>codex</option>
            <option value="cursor" ${(state.sessionProviderFilter || '').toLowerCase() === 'cursor' ? 'selected' : ''}>cursor</option>
            ${hasCopilot ? `<option value="copilot" ${(state.sessionProviderFilter || '').toLowerCase() === 'copilot' ? 'selected' : ''}>copilot</option>` : ''}
          </select>
          <select id="session-status-filter" class="filter-select">
            <option value="">所有状态</option>
            <option value="running" ${(state.sessionStatusFilter || '').toLowerCase() === 'running' ? 'selected' : ''}>运行中</option>
            <option value="idle" ${(state.sessionStatusFilter || '').toLowerCase() === 'idle' ? 'selected' : ''}>空闲</option>
            <option value="completed" ${(state.sessionStatusFilter || '').toLowerCase() === 'completed' ? 'selected' : ''}>已完成</option>
            <option value="needs approval" ${(state.sessionStatusFilter || '').toLowerCase() === 'needs approval' ? 'selected' : ''}>待审批</option>
            <option value="error" ${(state.sessionStatusFilter || '').toLowerCase() === 'error' ? 'selected' : ''}>错误</option>
            <option value="stopped" ${(state.sessionStatusFilter || '').toLowerCase() === 'stopped' ? 'selected' : ''}>已停止</option>
            <option value="unknown" ${(state.sessionStatusFilter || '').toLowerCase() === 'unknown' ? 'selected' : ''}>未知</option>
          </select>
          <button id="btn-clear-session-filters" class="btn btn-ghost btn-sm ${(state.sessionFilterQuery || state.sessionProviderFilter || state.sessionStatusFilter) ? '' : 'hidden'}">重置筛选</button>
        </div>
      </div>

      <div class="table-wrapper" title="点击行打开详情与 Checkpoint">
        <table class="data-table" id="sessions-table">
          <thead>
            <tr>
              <th class="col-title">会话 / 任务</th>
              <th class="col-project" style="width: 180px;">项目</th>
              <th class="col-status" style="width: 165px;">状态</th>
              <th class="col-time" style="width: 120px; text-align: right;">最后更新</th>
            </tr>
          </thead>
          <tbody id="sessions-table-body"></tbody>
        </table>
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
        showToast('已扫描并增量刷新会话');
      } catch (err) {
        showToast('刷新会话失败: ' + err.message, 'error');
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
    const tbody = document.getElementById('sessions-table-body');
    const emptyState = document.getElementById('sessions-empty-state');
    const tableWrapper = document.querySelector('.table-wrapper');
    if (!tbody) return;

    if (sessionsList.length === 0) {
      tbody.innerHTML = '';
      if (tableWrapper) tableWrapper.classList.add('hidden');
      if (emptyState) {
        emptyState.classList.remove('hidden');
        if (state.registeredProjects.length === 0) {
          // State 1: No connected projects
          emptyState.innerHTML = `
            <div class="empty-state-title">未连接本地项目</div>
            <div class="empty-state-desc">连接一个本地 Git 仓库或项目目录，Vela 才能观察与捕获智能体会话日志与工程上下文。</div>
            <button id="btn-empty-connect-proj" class="btn btn-primary btn-sm" style="margin-top: 12px;">+ 连接本地项目</button>
          `;
          const btn = document.getElementById('btn-empty-connect-proj');
          if (btn) btn.addEventListener('click', () => document.getElementById('btn-add-project').click());
        } else if (totalProjectSessions === 0 && !isFilterActive) {
          // State 2: Connected project has 0 logs
          emptyState.innerHTML = `
            <div class="empty-state-title">未检测到智能体会话日志</div>
            <div class="empty-state-desc">当前项目尚未发现智能体会话日志。启动 Claude Code、Cursor 或 Codex 进行工程开发，日志将在此自动更新。</div>
            <button id="btn-empty-refresh-scan" class="btn btn-secondary btn-sm" style="margin-top: 12px;">增量扫描会话日志</button>
          `;
          const btn = document.getElementById('btn-empty-refresh-scan');
          if (btn) btn.addEventListener('click', async () => {
            try {
              await callBridge('sessions.refresh');
              await refreshDashboard(true, true);
              showToast('已扫描并增量刷新会话');
            } catch (err) {
              showToast('刷新会话失败: ' + err.message, 'error');
            }
          });
        } else {
          // State 3: Filter query returned 0 matches
          emptyState.innerHTML = `
            <div class="empty-state-title">没有匹配的会话</div>
            <div class="empty-state-desc">没有符合当前搜索词或筛选条件的智能体会话。</div>
            <button id="btn-empty-clear-filters" class="btn btn-secondary btn-sm" style="margin-top: 12px;">清除筛选条件</button>
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

    if (tableWrapper) tableWrapper.classList.remove('hidden');
    if (emptyState) emptyState.classList.add('hidden');

    tbody.innerHTML = sessionsList.map(s => {
      const stateBadge = getSessionStateBadge(s.state);
      const tooltipParts = [];
      if (s.statusSource) tooltipParts.push(`状态来源: ${s.statusSource}`);
      if (s.statusInferred) tooltipParts.push(`状态依据: ${s.statusEvidence || '由日志推断，未附加实时常驻进程'}`);
      const cellTooltip = tooltipParts.join(' · ');
      return `
        <tr class="clickable-row ${state.selectedSessionId === s.id ? 'selected' : ''}" data-id="${escapeHtml(s.id)}">
          <td class="col-title" style="min-width: 0;">
            <div style="display: flex; align-items: center; gap: 8px; min-width: 0;">
              <span class="code-badge" style="flex-shrink: 0;">${escapeHtml(s.provider || 'AI')}</span>
              <button type="button" class="session-title-btn" data-id="${escapeHtml(s.id)}" title="${escapeHtml(s.title || '未命名会话')}" aria-label="查看会话: ${escapeHtml(s.title || '未命名会话')}">
                ${escapeHtml(s.title || '未命名会话')}
              </button>
            </div>
          </td>
          <td class="col-project">
            <div style="font-size: 12px; color: var(--text-secondary); overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title="${escapeHtml(s.project || '-')}">${escapeHtml(s.project ? s.project.split('/').pop() : '-')}</div>
          </td>
          <td class="col-status" style="white-space: nowrap; width: 165px;">
            <div ${cellTooltip ? `title="${escapeHtml(cellTooltip)}"` : ''} style="display: inline-flex; align-items: center; gap: 6px; white-space: nowrap;">
              ${stateBadge}
              ${s.statusInferred ? `<span class="status-badge status-amber" style="font-size: 10px; padding: 1px 5px; white-space: nowrap;" aria-label="状态由日志推断">日志推断</span>` : ''}
            </div>
          </td>
          <td class="col-time" style="font-size: 12px; color: var(--text-secondary); text-align: right; white-space: nowrap; width: 120px;">${formatTime(s.updatedAt || s.lastActivity)}</td>
        </tr>
      `;
    }).join('');

    tbody.querySelectorAll('tr.clickable-row').forEach(row => {
      const openRow = (triggerEl) => {
        const id = row.getAttribute('data-id');
        tbody.querySelectorAll('tr').forEach(r => r.classList.toggle('selected', r.getAttribute('data-id') === id));
        openSessionDetail(id, triggerEl || row.querySelector('.session-title-btn') || row);
      };

      row.addEventListener('click', () => {
        const trigger = row.querySelector('.session-title-btn') || row;
        openRow(trigger);
      });

      const titleBtn = row.querySelector('.session-title-btn');
      if (titleBtn) {
        titleBtn.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            openRow(titleBtn);
          }
        });
      }
    });
  }

  function getSessionStateBadge(stateStr) {
    const s = (stateStr || '').toLowerCase();
    switch (s) {
      case 'running':
        return '<span class="status-badge status-amber">● 运行中</span>';
      case 'completed':
        return '<span class="status-badge status-sage">✓ 已完成</span>';
      case 'needs approval':
      case 'needs_approval':
        return '<span class="status-badge status-amber">待审批</span>';
      case 'error':
        return '<span class="status-badge status-red">✕ 异常</span>';
      case 'failed':
        return '<span class="status-badge status-red">✕ 失败</span>';
      case 'idle':
        return '<span class="status-badge status-neutral">空闲</span>';
      case 'stopped':
        return '<span class="status-badge status-neutral">已停止</span>';
      case 'unknown':
      case '未知':
      case '未知（仅日志）':
        return '<span class="status-badge status-neutral">未知</span>';
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(stateStr || '未知')}</span>`;
    }
  }

  function renderSessionDetailContent(session, drawerBody) {
    const messages = session.messages || [];
    const isTruncated = Boolean(session.messagesTruncated || session.isPartial || session.partial);
    const tokenInputDisp = (session.tokenInput !== undefined && session.tokenInput !== null) ? formatNumber(session.tokenInput) : '未提供';
    const tokenOutputDisp = (session.tokenOutput !== undefined && session.tokenOutput !== null) ? formatNumber(session.tokenOutput) : '未提供';
    const tokensDisp = (session.tokenInput != null || session.tokenOutput != null) ? `${tokenInputDisp} / ${tokenOutputDisp}` : '未提供';

    drawerBody.innerHTML = `
      <div class="session-status-banner card" style="padding: 10px 14px; margin-bottom: 16px; background: var(--bg-subtle);">
        <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap;">
          <div style="display: flex; align-items: center; gap: 8px; flex-wrap: nowrap;">
            ${getSessionStateBadge(session.state)}
            ${session.statusInferred ? '<span class="status-badge status-amber" style="white-space: nowrap;">日志推断</span>' : ''}
            ${isTruncated ? '<span class="status-badge status-neutral" style="white-space: nowrap;">部分历史截断</span>' : ''}
          </div>
          <div style="font-size: 12px; color: var(--text-secondary); white-space: nowrap;">
            ${escapeHtml(session.provider || 'AI')}${session.model ? ` · ${escapeHtml(session.model)}` : ''}
          </div>
        </div>
        ${session.statusInferred ? `
          <div style="font-size: 11px; color: var(--text-muted); margin-top: 6px;">
            状态依据：${escapeHtml(session.statusEvidence || session.statusSource || '日志记录了完成事件，未附加实时常驻进程')}
          </div>
        ` : ''}
        ${isTruncated ? `
          <div style="font-size: 11px; color: var(--text-muted); margin-top: 4px;">
            提示：该会话历史记录较长，当前仅加载最新消息快照。
          </div>
        ` : ''}
      </div>

      <div style="margin-bottom: 20px;">
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
          <h3 style="font-size: 14px; font-weight: 600;">会话消息与工具调用 (${messages.length})</h3>
          <span style="font-size: 12px; color: var(--text-secondary);">单条消息可存为工程 Memory</span>
        </div>

        <div style="display: flex; flex-direction: column; gap: 12px;">
          ${messages.length === 0 ? '<div class="text-secondary" style="font-size: 13px; padding: 24px 0; text-align: center;">无详细消息记录（仅捕获会话级统计）</div>' : ''}
          ${messages.map((m, idx) => `
            <div class="card" style="margin-bottom: 0; padding: 12px 14px;">
              <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;">
                <div style="display: flex; align-items: center; gap: 8px;">
                  <span class="status-badge status-neutral">${escapeHtml(m.role || 'message')}</span>
                  <span style="font-size: 12px; color: var(--text-muted);">${formatTime(m.timestamp)}</span>
                </div>
                <button class="btn btn-ghost btn-sm btn-save-msg-memory" data-idx="${idx}" title="保存此消息为 Memory">
                  + 存为 Memory
                </button>
              </div>
              <div style="font-size: 13px; line-height: 1.55; white-space: pre-wrap; word-break: break-word; color: var(--text-main); font-family: var(--font-system);">${escapeHtml(m.content || '')}</div>
              ${m.tool ? `
                <div style="margin-top: 8px; font-size: 12px; font-family: var(--font-mono); color: var(--text-secondary); background: var(--bg-subtle); padding: 6px 10px; border-radius: 4px; border: 1px solid var(--border-color);">
                  <div style="font-weight: 600; margin-bottom: ${m.input || m.output ? '4px' : '0'};">工具调用: ${escapeHtml(m.tool)}</div>
                  ${m.input ? `<div style="font-size: 11px; white-space: pre-wrap; word-break: break-all; color: var(--text-muted);">${escapeHtml(typeof m.input === 'string' ? m.input : JSON.stringify(m.input, null, 2))}</div>` : ''}
                  ${m.output ? `<div style="font-size: 11px; white-space: pre-wrap; word-break: break-all; color: var(--text-secondary); margin-top: 4px; border-top: 1px dashed var(--border-color); padding-top: 4px;">${escapeHtml(typeof m.output === 'string' ? m.output : JSON.stringify(m.output, null, 2))}</div>` : ''}
                </div>` : ''}
            </div>
          `).join('')}
        </div>
      </div>

      <details class="card" style="padding: 12px 14px;" ${messages.length === 0 ? 'open' : ''}>
        <summary style="cursor: pointer; font-size: 13px; font-weight: 600; user-select: none;">
          技术元数据与执行环境
        </summary>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px; font-size: 12px; margin-top: 12px;">
          <div style="grid-column: 1 / -1;"><span class="text-secondary">会话 ID:</span> <span class="font-mono" style="word-break: break-all; user-select: all;">${escapeHtml(session.id || '')}</span></div>
          <div><span class="text-secondary">Provider:</span> <strong>${escapeHtml(session.provider || '-')}</strong></div>
          <div><span class="text-secondary">Model:</span> <span class="font-mono">${escapeHtml(session.model || '-')}</span></div>
          <div><span class="text-secondary">Project:</span> <span class="font-mono">${escapeHtml(session.project || '-')}</span></div>
          <div><span class="text-secondary">Branch:</span> <span class="font-mono">${escapeHtml(session.branch || '-')}</span></div>
          <div><span class="text-secondary">Tokens (I/O):</span> <span class="font-mono">${tokensDisp}</span></div>
          <div><span class="text-secondary">时间:</span> ${formatTime(session.updatedAt)}</div>
          ${session.statusSource ? `<div><span class="text-secondary">状态来源:</span> <span class="font-mono">${escapeHtml(session.statusSource)}</span></div>` : ''}
          ${session.statusInferred ? `<div><span class="text-secondary">状态判定:</span> <span style="color: var(--status-amber-text, #f59e0b);" aria-label="状态由日志推断">状态由日志推断</span></div>` : ''}
        </div>
        ${session.sourcePath ? `<div style="margin-top: 10px; font-size: 12px; font-family: var(--font-mono); color: var(--text-muted); word-break: break-all;">日志路径: ${escapeHtml(session.sourcePath)}</div>` : ''}
      </details>
    `;

    drawerBody.querySelectorAll('.btn-save-msg-memory').forEach(btn => {
      btn.addEventListener('click', () => {
        const idx = parseInt(btn.getAttribute('data-idx'), 10);
        const msg = messages[idx];
        openCreateOrEditMemoryModal({
          title: (session.title || '会话经验') + ` - 摘录`,
          content: msg.content || '',
          type: 'fact',
          scope: 'project',
          project: session.project || '',
          branch: session.branch || '',
          sourceSession: session.id,
          sourceMessage: msg.id || String(idx)
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

  async function openSessionDetail(sessionId, triggerEl = null) {
    const thisSeq = ++sessionDetailSequence;
    const thisProject = state.currentProject;
    state.selectedSessionId = sessionId;
    openDrawer('正在加载会话详情...', '会话', triggerEl);

    try {
      const session = await callBridge('sessions.get', { id: sessionId });
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');

      if (thisSeq !== sessionDetailSequence || state.selectedSessionId !== sessionId || !isDrawerOpen || state.currentProject !== thisProject) {
        return;
      }
      if (!session) throw new Error('会话不存在');

      const fp = computeSessionFingerprint(session);
      state.loadedSessionDetail = {
        id: session.id,
        fingerprint: fp,
        rev: fp
      };

      const shortSubtitle = [
        session.provider || 'AI',
        session.project ? session.project.split('/').pop() : '全局'
      ].filter(Boolean).join(' · ');

      setDrawerTitle(session.title || '会话详情', shortSubtitle);
      setDrawerCustomActions(`
        <button id="btn-save-checkpoint-modal" class="btn btn-secondary btn-sm" style="flex-shrink: 0;">保存 Checkpoint</button>
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
      }
    } catch (err) {
      const drawer = document.getElementById('detail-drawer');
      const isDrawerOpen = drawer && !drawer.classList.contains('hidden');
      if (thisSeq !== sessionDetailSequence || state.selectedSessionId !== sessionId || !isDrawerOpen || state.currentProject !== thisProject) {
        return;
      }
      setDrawerTitle('加载失败', '错误');
      const drawerBody = document.getElementById('drawer-content');
      if (drawerBody) {
        drawerBody.innerHTML = `
          <div class="alert-banner alert-danger">
            无法获取会话详情：${escapeHtml(err.message)}
          </div>
        `;
      }
    }
  }

  // -------------------------------------------------------------------------
  // 2. WORKFLOWS VIEW (With deterministic workflow builder draft)
  // -------------------------------------------------------------------------
  function renderWorkflowsView(container) {
    const workflows = (state.dashboard && state.dashboard.workflows) || [];
    const runs = (state.dashboard && state.dashboard.runs) || [];

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>工作流</h1>
          <p>确定性多步骤自动化编排 · 安全工具门禁 · 运行记录与试运行</p>
        </div>
        <div class="page-actions">
          <button id="btn-build-wf-prompt" class="btn btn-secondary btn-sm">描述工作流</button>
          <button id="btn-new-workflow" class="btn btn-primary btn-sm">+ 新建工作流</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.workflowsActiveTab === 'list' ? 'active' : ''}" data-wftab="list">工作流列表 (${workflows.length})</button>
        <button class="tab-btn ${state.workflowsActiveTab === 'runs' ? 'active' : ''}" data-wftab="runs">运行记录 (${runs.length})</button>
        <button class="tab-btn ${state.workflowsActiveTab === 'health' ? 'active' : ''}" data-wftab="health">健康度检测</button>
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
            <div class="empty-state-title">未配置工作流</div>
            <div class="empty-state-desc">创建多步骤自动化工作流，如 Git 检查、类型测试验证等。所有写操作和执行均受安全审查门禁保护。</div>
            <div style="display: flex; gap: 8px; margin-top: 12px;">
              <button id="btn-empty-build-wf" class="btn btn-secondary btn-sm">描述生成草稿</button>
              <button id="btn-empty-create-wf" class="btn btn-primary btn-sm">+ 创建工作流</button>
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
                <th>工作流名称</th>
                <th>触发方式 (Trigger)</th>
                <th>步骤数</th>
                <th>版本</th>
                <th>状态</th>
                <th style="text-align: right; width: 220px;">操作</th>
              </tr>
            </thead>
            <tbody>
              ${workflows.map(wf => `
                <tr>
                  <td>
                    <strong>${escapeHtml(wf.title || '未命名')}</strong>
                    <div style="font-size: 12px; color: var(--text-secondary);">${escapeHtml(wf.description || '-')}</div>
                  </td>
                  <td>
                    <span class="code-badge">${escapeHtml(wf.trigger || 'manual')}</span>
                    ${wf.cron ? `<span style="font-size: 12px; font-family: var(--font-mono); color: var(--text-muted); margin-left: 4px;">${escapeHtml(wf.cron)}</span>` : ''}
                  </td>
                  <td>${(wf.steps && wf.steps.length) || 0} 步</td>
                  <td><span class="font-mono">v${escapeHtml(String(wf.version || 1))}</span></td>
                  <td>
                    ${wf.enabled !== false ? '<span class="status-badge status-sage">已启用</span>' : '<span class="status-badge status-neutral">已停用</span>'}
                  </td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-wf-dryrun" data-id="${escapeHtml(wf.id)}" title="不触发写入的只读试运行">Dry Run</button>
                    <button class="btn btn-primary btn-sm btn-wf-run" data-id="${escapeHtml(wf.id)}">运行</button>
                    <button class="btn btn-ghost btn-sm btn-wf-edit" data-id="${escapeHtml(wf.id)}">编辑</button>
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
            showToast('已触发工作流运行');
            await refreshDashboard(true, true);
            if (run && run.id) openRunDetail(run.id);
          } catch (err) {
            showToast('运行失败: ' + err.message, 'error');
          }
        });
      });

      target.querySelectorAll('.btn-wf-dryrun').forEach(btn => {
        btn.addEventListener('click', async () => {
          const id = btn.getAttribute('data-id');
          try {
            const run = await callBridge('workflows.run', { id, dryRun: true });
            showToast('Dry Run (试运行) 完成');
            await refreshDashboard(true, true);
            if (run && run.id) openRunDetail(run.id);
          } catch (err) {
            showToast('Dry Run 失败: ' + err.message, 'error');
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
            <div class="empty-state-title">暂无运行记录</div>
            <div class="empty-state-desc">运行工作流后，所有步骤执行输出、持续耗时与版本快照将在此形成审计账本。</div>
          </div>
        `;
        return;
      }

      target.innerHTML = `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th>运行 ID</th>
                <th>工作流</th>
                <th>模式</th>
                <th>状态</th>
                <th>耗时</th>
                <th>触发时间</th>
                <th style="text-align: right; width: 140px;">操作</th>
              </tr>
            </thead>
            <tbody>
              ${runs.map(r => `
                <tr class="clickable-row" data-id="${escapeHtml(r.id)}">
                  <td><span class="code-badge">${escapeHtml(r.id ? r.id.substring(0, 8) : '-')}</span></td>
                  <td><strong>${escapeHtml(r.title || r.workflowId || '未命名')}</strong></td>
                  <td>${r.dryRun ? '<span class="status-badge status-neutral">Dry Run</span>' : '<span class="status-badge status-sage">执行</span>'}</td>
                  <td>${getRunStateBadge(r.state)}</td>
                  <td><span class="font-mono">${r.durationMs ? escapeHtml(String(r.durationMs)) + 'ms' : '-'}</span></td>
                  <td>${formatTime(r.startedAt)}</td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-replay-run" data-id="${escapeHtml(r.id)}">重放</button>
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
            showToast('已重放工作流');
            await refreshDashboard(true, true);
          } catch (err) {
            showToast('重放失败: ' + err.message, 'error');
          }
        });
      });

    } else if (state.workflowsActiveTab === 'health') {
      target.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title">工作流健康度统计 (workflows.health)</span>
            <button id="btn-refresh-health" class="btn btn-ghost btn-sm">刷新健康状态</button>
          </div>
          <div id="health-stats-container">
            <div class="stat-grid">
              <div class="stat-card">
                <div class="stat-label">总运行次数 (runs)</div>
                <div class="stat-value" id="health-total-runs">-</div>
                <div class="stat-sub" id="health-success-detail">-</div>
              </div>
              <div class="stat-card">
                <div class="stat-label">执行成功率 (successRate)</div>
                <div class="stat-value" id="health-success-rate">-</div>
                <div class="stat-sub" id="health-approval-rejected">-</div>
              </div>
              <div class="stat-card">
                <div class="stat-label">平均耗时 (averageDurationMs)</div>
                <div class="stat-value" id="health-avg-duration">-</div>
                <div class="stat-sub" id="health-tokens-stat">Token 消耗: 未提供</div>
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
        document.getElementById('health-total-runs').textContent = h.runs !== undefined && h.runs !== null ? formatNumber(h.runs) : '未提供';
        document.getElementById('health-success-detail').textContent = (h.successes !== undefined && h.failures !== undefined)
          ? `成功: ${h.successes} · 失败: ${h.failures}` : '';
        
        document.getElementById('health-success-rate').textContent = (h.successRate !== null && h.successRate !== undefined)
          ? (h.successRate * 100).toFixed(1) + '%' : '未提供';
        
        document.getElementById('health-approval-rejected').textContent = h.approvalRejected !== undefined
          ? `审批被拒: ${h.approvalRejected} 次` : '';

        document.getElementById('health-avg-duration').textContent = (h.averageDurationMs !== null && h.averageDurationMs !== undefined)
          ? Math.round(h.averageDurationMs) + 'ms' : '未提供';

        document.getElementById('health-tokens-stat').textContent = h.tokensAvailable && h.tokens !== null
          ? `Token 消耗: ${formatNumber(h.tokens)}` : 'Token 统计: 未提供';
      }
    } catch {
      document.getElementById('health-total-runs').textContent = '未提供';
      document.getElementById('health-success-rate').textContent = '未提供';
      document.getElementById('health-avg-duration').textContent = '未提供';
    }
  }

  function getRunStateBadge(st) {
    switch (st) {
      case 'Completed':
      case 'Success':
        return '<span class="status-badge status-sage">✓ 成功</span>';
      case 'Running':
        return '<span class="status-badge status-amber">● 运行中</span>';
      case 'Failed':
      case 'Error':
        return '<span class="status-badge status-red">失败</span>';
      case 'Pending Approval':
        return '<span class="status-badge status-amber">待审批</span>';
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(st || '未知')}</span>`;
    }
  }

  async function openRunDetail(runId) {
    state.selectedRunId = runId;
    openDrawer('正在加载运行审计记录...', '运行审计');

    try {
      const run = await callBridge('runs.get', { id: runId });
      if (!run) throw new Error('未找到该运行记录');

      setDrawerTitle(run.title || '运行详情', run.id ? `运行 · ${run.id.substring(0, 8)}` : '运行审计');
      setDrawerCustomActions(`
        <button id="btn-drawer-replay" class="btn btn-secondary btn-sm">重放运行</button>
      `);

      document.getElementById('btn-drawer-replay').addEventListener('click', async () => {
        try {
          await callBridge('workflows.replay', { runId: run.id });
          showToast('已提交重放');
          closeDrawer();
          await refreshDashboard(true, true);
        } catch (e) {
          showToast('重放失败: ' + e.message, 'error');
        }
      });

      const steps = run.steps || [];
      const drawerBody = document.getElementById('drawer-content');

      drawerBody.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title">基本信息</span>
            ${getRunStateBadge(run.state)}
          </div>
          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 11px;">
            <div><span class="text-secondary">模式:</span> <strong>${run.dryRun ? 'Dry Run (只读试运行)' : '实际执行'}</strong></div>
            <div><span class="text-secondary">版本:</span> v${escapeHtml(String(run.workflowVersion || 1))}</div>
            <div><span class="text-secondary">耗时:</span> ${run.durationMs ? escapeHtml(String(run.durationMs)) + 'ms' : '-'}</div>
            <div><span class="text-secondary">触发:</span> ${formatTime(run.startedAt)}</div>
          </div>
        </div>

        <div>
          <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;">执行步骤 (${steps.length})</h3>
          <div style="display: flex; flex-direction: column; gap: 10px;">
            ${steps.map((step, idx) => `
              <div class="card" style="margin-bottom: 0; padding: 10px 12px;">
                <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
                  <div>
                    <strong>${idx + 1}. ${escapeHtml(step.title || '步骤')}</strong>
                    <span class="code-badge" style="margin-left: 6px;">${escapeHtml(step.tool || '')}</span>
                  </div>
                  <div style="display: flex; align-items: center; gap: 6px;">
                    ${step.durationMs ? `<span style="font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(String(step.durationMs))}ms</span>` : ''}
                    ${getRunStateBadge(step.state)}
                  </div>
                </div>
                ${step.output ? `
                  <div class="code-view" style="max-height: 160px; font-size: 12px;">${escapeHtml(typeof step.output === 'string' ? step.output : JSON.stringify(step.output, null, 2))}</div>
                ` : '<div style="font-size: 12px; color: var(--text-muted);">（无输出）</div>'}
              </div>
            `).join('')}
          </div>
        </div>
      `;
    } catch (err) {
      setDrawerTitle('加载失败', '错误');
      document.getElementById('drawer-content').innerHTML = `
        <div class="alert-banner alert-danger">无法加载运行详情：${escapeHtml(err.message)}</div>
      `;
    }
  }

  function openWorkflowPromptBuilderModal() {
    const modalBody = `
      <div class="alert-banner alert-info">
        <span>基于描述由本地确定性模板生成工作流草稿。生成后将载入编辑器供您审查与修改，不会自动保存或执行。</span>
      </div>
      <div class="form-group">
        <label class="form-label">目标项目</label>
        <select id="wf-build-project" class="form-select">
          ${state.registeredProjects.map(p => `
            <option value="${escapeHtml(p.path || p.id)}" ${(state.currentProject === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
          `).join('')}
        </select>
      </div>
      <div class="form-group">
        <label class="form-label">需求描述 (Prompt)</label>
        <textarea id="wf-build-desc" class="form-textarea" placeholder="例如：每次执行单元测试前先检查 git status，若测试通过则写入 CHANGELOG 更新记录"></textarea>
      </div>
    `;

    openModal('描述生成工作流草稿 (workflows.build)', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-wf-build">取消</button>
      <button class="btn btn-primary" id="btn-confirm-wf-build">生成草稿</button>
    `);

    document.getElementById('btn-cancel-wf-build').addEventListener('click', closeModal);
    document.getElementById('btn-confirm-wf-build').addEventListener('click', async () => {
      const project = document.getElementById('wf-build-project').value;
      const description = document.getElementById('wf-build-desc').value.trim();

      if (!project) {
        showToast('请先选择项目', 'error');
        return;
      }
      if (!description) {
        showToast('请输入工作流描述', 'error');
        return;
      }

      try {
        const res = await callBridge('workflows.build', { project, description });
        closeModal();

        if (res && res.workflow) {
          showToast(res.message || '工作流草稿生成成功');
          // Load draft into editor
          openEditWorkflowModal(res.workflow, res.unresolvedInputs || []);
        }
      } catch (err) {
        showToast('生成草稿失败: ' + err.message, 'error');
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
          <span>待补全参数：${escapeHtml(unresolvedInputs.join('、'))}</span>
        </div>
      ` : ''}
      <div class="form-group">
        <label class="form-label">工作流标题</label>
        <input type="text" id="wf-modal-title" class="form-input" value="${escapeHtml(wf ? wf.title : '代码变更安全审查')}" placeholder="输入工作流标题">
      </div>
      <div class="form-group">
        <label class="form-label">所属项目</label>
        <select id="wf-modal-project" class="form-select">
          ${state.registeredProjects.map(p => `
            <option value="${escapeHtml(p.path || p.id)}" ${(wf && wf.project === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
          `).join('')}
        </select>
      </div>
      <div class="form-group">
        <label class="form-label">描述</label>
        <input type="text" id="wf-modal-desc" class="form-input" value="${escapeHtml(wf ? wf.description || '' : '自动化审查 Git 状态与测试套件')}" placeholder="工作流说明">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">触发模式</label>
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
          <label class="form-label">Cron 表达式</label>
          <input type="text" id="wf-modal-cron" class="form-input" value="${escapeHtml(wf ? wf.cron || '' : '0 * * * *')}" placeholder="*/30 * * * *">
        </div>
      </div>

      <div style="margin-top: 6px;">
        <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
          <label class="form-label" style="margin-bottom: 0;">执行步骤 (Ordered Steps)</label>
          <button type="button" id="btn-add-step" class="btn btn-ghost btn-sm">+ 添加步骤</button>
        </div>
        <div id="wf-steps-list" style="display: flex; flex-direction: column; gap: 8px; max-height: 240px; overflow-y: auto;"></div>
      </div>
    `;

    openModal(isEdit ? '编辑工作流' : '新建工作流', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-wf">取消</button>
      <button class="btn btn-primary" id="btn-save-wf">保存工作流</button>
    `);

    const renderSteps = () => {
      const container = document.getElementById('wf-steps-list');
      if (!container) return;
      container.innerHTML = steps.map((s, idx) => `
        <div class="card" style="padding: 8px 10px; margin-bottom: 0; background: var(--bg-subtle);">
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
            <input type="text" class="form-input wf-step-title" data-idx="${idx}" value="${escapeHtml(s.title || '')}" placeholder="步骤名称" style="width: 160px; font-size: 11px; padding: 2px 6px;">
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
              <button type="button" class="btn-icon-subtle btn-step-up" data-idx="${idx}" title="上移">↑</button>
              <button type="button" class="btn-icon-subtle btn-step-down" data-idx="${idx}" title="下移">↓</button>
              <button type="button" class="btn-icon-subtle btn-step-del" data-idx="${idx}" title="删除" style="color: var(--status-red-text);">×</button>
            </div>
          </div>
          <div>
            <textarea class="form-textarea code-editor wf-step-args" data-idx="${idx}" style="min-height: 56px; font-size: 12px; padding: 6px 8px;" placeholder="${s.tool === 'agent.run' ? '请输入已安装的 CLI 可执行文件 (executable) 与参数 (args)...' : '参数 JSON'}">${escapeHtml(typeof s.arguments === 'object' ? JSON.stringify(s.arguments, null, 2) : s.arguments || '{}')}</textarea>
            ${s.tool === 'agent.run' ? '<div style="font-size: 12px; color: var(--text-secondary); margin-top: 4px;">提示：须填写真实已安装的 CLI 可执行文件 (executable) 与参数数组 (args)。</div>' : ''}
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
        title: '新步骤',
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
        showToast('请输入工作流标题', 'error');
        return;
      }
      if (!project) {
        showToast('请选择所属项目', 'error');
        return;
      }

      for (const s of steps) {
        if (typeof s.arguments === 'string') {
          try {
            s.arguments = JSON.parse(s.arguments);
          } catch {
            showToast(`步骤 "${s.title}" 的参数 JSON 格式无效`, 'error');
            return;
          }
        }
        if (['agent.run', 'shell.test', 'shell.typecheck'].includes(s.tool)) {
          const argsObj = s.arguments;
          if (!argsObj || typeof argsObj !== 'object' || Array.isArray(argsObj)) {
            showToast(`步骤 "${s.title}" 的参数必须为 JSON 对象`, 'error');
            return;
          }
          if (typeof argsObj.executable !== 'string' || !argsObj.executable.trim()) {
            showToast(`步骤 "${s.title}" (${s.tool}) 必须指定有效的 executable 可执行程序`, 'error');
            return;
          }
          if (!Array.isArray(argsObj.args) || !argsObj.args.every(a => typeof a === 'string')) {
            showToast(`步骤 "${s.title}" (${s.tool}) 的 args 必须为字符串数组`, 'error');
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
        showToast('工作流已保存');
        closeModal();
        await refreshDashboard(true, true);
      } catch (err) {
        showToast('保存工作流失败: ' + err.message, 'error');
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
          <h1>配置与资产</h1>
          <p>工程规则、MCP 协议、环境规约、持久 Memory 与本地知识库</p>
        </div>
        <div class="page-actions">
          <button id="btn-scan-setup" class="btn btn-secondary btn-sm">扫描配置</button>
          <button id="btn-audit-setup" class="btn btn-secondary btn-sm">配置审计</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.setupActiveTab === 'rules' ? 'active' : ''}" data-setuptab="rules">Rules 规则</button>
        <button class="tab-btn ${state.setupActiveTab === 'skills' ? 'active' : ''}" data-setuptab="skills">Skills 技能</button>
        <button class="tab-btn ${state.setupActiveTab === 'hooks' ? 'active' : ''}" data-setuptab="hooks">Hooks 钩子</button>
        <button class="tab-btn ${state.setupActiveTab === 'mcp' ? 'active' : ''}" data-setuptab="mcp">MCP 协议</button>
        <button class="tab-btn ${state.setupActiveTab === 'guidelines' ? 'active' : ''}" data-setuptab="guidelines">Guidelines 指南</button>
        <button class="tab-btn ${state.setupActiveTab === 'memory' ? 'active' : ''}" data-setuptab="memory">Memory 记忆</button>
        <button class="tab-btn ${state.setupActiveTab === 'library' ? 'active' : ''}" data-setuptab="library">Library 知识库</button>
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
        showToast('已扫描配置资产');
        await refreshDashboard(true, true);
      } catch (e) {
        showToast('扫描失败: ' + e.message, 'error');
      }
    });

    document.getElementById('btn-audit-setup').addEventListener('click', async () => {
      try {
        const res = await callBridge('setup.audit', state.currentProject ? { project: state.currentProject } : {});
        const diag = (res && res.diagnostics) || [];
        if (diag.length === 0) {
          showToast('审计通过：未发现配置问题', 'info');
        } else {
          showToast(`审计完成，发现 ${diag.length} 项诊断提示`, 'warning');
        }
      } catch (e) {
        showToast('审计失败: ' + e.message, 'error');
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
        <span class="text-secondary" style="font-size: 13px;">共 ${filtered.length} 项 ${escapeHtml(typeName)} 资产 · 本地只读预览与定位</span>
      </div>

      ${filtered.length === 0 ? `
        <div class="empty-state">
          <div class="empty-state-title">未检测到 ${escapeHtml(typeName)} 资产</div>
          <div class="empty-state-desc">在当前项目根目录或 ~/.vela/ 中放置对应的规约与脚本，Vela 会自动索引并展示诊断信息。</div>
        </div>
      ` : `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th>标题 / 标识</th>
                <th>Provider / 作用域</th>
                <th>估算 Tokens</th>
                <th>哈希 (SHA256)</th>
                <th>诊断</th>
                <th style="text-align: right; width: 140px;">操作</th>
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
                      ? `<span class="status-badge status-amber">${a.diagnostics.length} 项警告</span>`
                      : '<span class="status-badge status-sage">✓ 正常</span>'}
                  </td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-preview-artifact" data-id="${escapeHtml(a.id)}">预览</button>
                    ${a.path ? `<button class="btn btn-ghost btn-sm btn-reveal-path" data-path="${escapeHtml(a.path)}">定位</button>` : ''}
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
          openDrawer(art.title || '配置详情', art.path);
          document.getElementById('drawer-content').innerHTML = `
            <div class="card">
              <div class="card-header"><span class="card-title">基本信息</span></div>
              <div style="font-size: 12px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                <div><span class="text-secondary">类型:</span> ${escapeHtml(art.type)}</div>
                <div><span class="text-secondary">Provider:</span> ${escapeHtml(art.provider)}</div>
                <div><span class="text-secondary">Token 估算:</span> ${escapeHtml(String(art.tokens || '-'))}</div>
                <div><span class="text-secondary">Hash:</span> <span class="font-mono">${escapeHtml(art.hash || '-')}</span></div>
              </div>
              <div style="margin-top: 8px; font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);">路径: ${escapeHtml(art.path || '-')}</div>
            </div>
            <div>
              <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;">只读内容预览</h3>
              <div class="code-view">${escapeHtml(art.content || '(无内容)')}</div>
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
          showToast('定位失败: ' + e.message, 'error');
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
        <span class="text-secondary" style="font-size: 12px;">已维护 Guidelines 指南规约 · 支持按项目或全局定义</span>
        <button id="btn-new-guideline" class="btn btn-primary btn-sm">+ 新建 Guideline</button>
      </div>
      <div id="guidelines-list-container">
        <div class="text-secondary" style="font-size: 12px; padding: 20px 0;">加载中...</div>
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
            <div class="empty-state-title">未配置 Guidelines 指南</div>
            <div class="empty-state-desc">为项目建立编码与架构指南。保留静态源快照归档，不直接修改工程代码。</div>
            <button id="btn-empty-add-gl" class="btn btn-primary btn-sm" style="margin-top: 12px;">+ 创建指南</button>
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
                <th>标题</th>
                <th>作用域 (Scope)</th>
                <th>关联项目</th>
                <th>最后更新</th>
                <th style="text-align: right; width: 140px;">操作</th>
              </tr>
            </thead>
            <tbody>
              ${list.map(g => `
                <tr>
                  <td><strong>${escapeHtml(g.title || g.id)}</strong></td>
                  <td><span class="code-badge">${escapeHtml(g.scope || 'project')}</span></td>
                  <td style="font-size: 11px; color: var(--text-secondary);">${escapeHtml(g.project ? g.project.split('/').pop() : '全局')}</td>
                  <td style="font-size: 11px; color: var(--text-secondary);">${formatTime(g.updatedAt || g.createdAt)}</td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-view-gl" data-id="${escapeHtml(g.id)}">查看</button>
                    <button class="btn btn-ghost btn-sm btn-edit-gl" data-id="${escapeHtml(g.id)}">编辑</button>
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
            openDrawer(g.title || 'Guideline 指南', g.id);
            document.getElementById('drawer-content').innerHTML = `
              <div class="card">
                <div class="card-header">
                  <span class="card-title">基本信息</span>
                  <span class="status-badge status-neutral">快照记录 (未注入执行)</span>
                </div>
                <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
                  <div><span class="text-secondary">作用域:</span> ${escapeHtml(g.scope || 'project')}</div>
                  <div><span class="text-secondary">项目:</span> ${escapeHtml(g.project || '全局')}</div>
                  <div><span class="text-secondary">生效模式:</span> 静态快照（未注入上下文）</div>
                  <div><span class="text-secondary">运行时影响:</span> 仅本地归档，不改变外部智能体运行时</div>
                </div>
              </div>
              <div>
                <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;">指南快照内容</h3>
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
          <div class="alert-banner alert-danger">加载 Guidelines 失败: ${escapeHtml(err.message)}</div>
        `;
      }
    }
  }

  function openCreateOrEditGuidelineModal(initial = null) {
    const isEdit = !!(initial && initial.id);
    const modalBody = `
      <div class="form-group">
        <label class="form-label">指南标题</label>
        <input type="text" id="gl-title" class="form-input" value="${escapeHtml(initial ? initial.title : '')}" placeholder="例如：API 接口设计原则与命名规范">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">作用域 (Scope)</label>
          <select id="gl-scope" class="form-select">
            <option value="project" ${(initial && initial.scope === 'project') ? 'selected' : ''}>项目作用域</option>
            <option value="global" ${(initial && initial.scope === 'global') ? 'selected' : ''}>全局作用域</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">关联项目</label>
          <select id="gl-project" class="form-select">
            <option value="">(无 / 全局)</option>
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}" ${(initial && initial.project === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
      </div>
      <div class="form-group">
        <label class="form-label">Markdown 内容</label>
        <textarea id="gl-content" class="form-textarea code-editor" style="min-height: 140px;" placeholder="编写 Markdown 格式规约">${escapeHtml(initial ? initial.content || '' : '')}</textarea>
      </div>
    `;

    openModal(isEdit ? '编辑 Guideline' : '新建 Guideline', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-gl">取消</button>
      <button class="btn btn-primary" id="btn-save-gl">保存 Guideline</button>
    `);

    document.getElementById('btn-cancel-gl').addEventListener('click', closeModal);
    document.getElementById('btn-save-gl').addEventListener('click', async () => {
      const title = document.getElementById('gl-title').value.trim();
      const scope = document.getElementById('gl-scope').value;
      const project = document.getElementById('gl-project').value;
      const content = document.getElementById('gl-content').value.trim();

      if (!title || !content) {
        showToast('标题与内容不能为空', 'error');
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
        showToast('Guideline 已保存');
        closeModal();
        renderGuidelinesSection(document.getElementById('setup-tab-content'));
      } catch (err) {
        showToast('保存失败: ' + err.message, 'error');
      }
    });
  }

  // --- Complete Memory Management (Normalized lowercase, provenance, edit, supersede) ---
  function renderMemorySection(target) {
    const memories = (state.dashboard && state.dashboard.memories) || [];

    target.innerHTML = `
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
        <span class="text-secondary" style="font-size: 12px;">
          已沉淀 Memory 条目 (${memories.length}) · 状态流转：Candidate ➔ Active ➔ Superseded ➔ Archived
        </span>
        <div style="display: flex; gap: 8px;">
          <button id="btn-recall-tester" class="btn btn-secondary btn-sm">Recall 召回测试</button>
          <button id="btn-new-memory" class="btn btn-primary btn-sm">+ 新建 Memory</button>
        </div>
      </div>

      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th>标题</th>
              <th>作用域 (Scope)</th>
              <th>类型</th>
              <th>状态</th>
              <th>关联来源 (Provenance)</th>
              <th style="text-align: right; width: 240px;">操作</th>
            </tr>
          </thead>
          <tbody>
            ${memories.length === 0 ? '<tr><td colspan="6" style="text-align: center; color: var(--text-muted); padding: 24px;">暂无 Memory 条目</td></tr>' : ''}
            ${memories.map(m => {
              const st = (m.state || 'candidate').toLowerCase();
              const provenance = m.sourceSession ? ('会话: ' + escapeHtml(m.sourceSession.substring(0, 8))) :
                                 (m.sourceFile ? ('文件: ' + escapeHtml(m.sourceFile)) :
                                 (m.sourceCommit ? ('提交: ' + escapeHtml(m.sourceCommit.substring(0, 7))) : '-'));
              return `
                <tr>
                  <td>
                    <strong>${escapeHtml(m.title || '未命名')}</strong>
                    <div style="font-size: 11px; color: var(--text-secondary); max-width: 260px; text-overflow: ellipsis; overflow: hidden; white-space: nowrap;">${escapeHtml(m.content || '')}</div>
                  </td>
                  <td><span class="code-badge">${escapeHtml(m.scope || 'project')}</span></td>
                  <td><span style="font-size: 12px; color: var(--text-secondary);">${escapeHtml(m.type || 'fact')}</span></td>
                  <td>${getMemoryStateBadge(st)}</td>
                  <td style="font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);">${provenance}</td>
                  <td style="text-align: right;">
                    ${st === 'candidate' ? `<button class="btn btn-secondary btn-sm btn-mem-activate" data-id="${escapeHtml(m.id)}">激活</button>` : ''}
                    ${st === 'active' ? `<button class="btn btn-ghost btn-sm btn-mem-supersede" data-id="${escapeHtml(m.id)}" title="被其它条目替代">替代</button>` : ''}
                    ${st !== 'archived' ? `<button class="btn btn-ghost btn-sm btn-mem-archive" data-id="${escapeHtml(m.id)}">归档</button>` : ''}
                    <button class="btn btn-ghost btn-sm btn-mem-edit" data-id="${escapeHtml(m.id)}">编辑</button>
                    <button class="btn btn-ghost btn-sm btn-mem-view" data-id="${escapeHtml(m.id)}">详情</button>
                  </td>
                </tr>
              `;
            }).join('')}
          </tbody>
        </table>
      </div>
    `;

    document.getElementById('btn-new-memory').addEventListener('click', () => openCreateOrEditMemoryModal());
    document.getElementById('btn-recall-tester').addEventListener('click', openRecallModal);

    target.querySelectorAll('.btn-mem-activate').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-id');
        try {
          await callBridge('memory.transition', { id, state: 'active' });
          showToast('已激活 Memory');
          await refreshDashboard(true, true);
        } catch (e) {
          showToast('激活失败: ' + e.message, 'error');
        }
      });
    });

    target.querySelectorAll('.btn-mem-archive').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-id');
        try {
          await callBridge('memory.transition', { id, state: 'archived' });
          showToast('已归档 Memory');
          await refreshDashboard(true, true);
        } catch (e) {
          showToast('归档失败: ' + e.message, 'error');
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

    target.querySelectorAll('.btn-mem-view').forEach(btn => {
      btn.addEventListener('click', () => {
        const id = btn.getAttribute('data-id');
        const m = memories.find(item => item.id === id);
        if (m) {
          openDrawer(m.title || 'Memory 条目', m.id);
          document.getElementById('drawer-content').innerHTML = `
            <div class="card">
              <div class="card-header">
                <span class="card-title">元数据 &amp; 来源溯源 (Provenance)</span>
                ${getMemoryStateBadge(m.state)}
              </div>
              <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 6px; font-size: 11px;">
                <div><span class="text-secondary">类型:</span> ${escapeHtml(m.type)}</div>
                <div><span class="text-secondary">作用域:</span> ${escapeHtml(m.scope)}</div>
                <div><span class="text-secondary">项目:</span> ${escapeHtml(m.project || '-')}</div>
                <div><span class="text-secondary">分支:</span> <span class="font-mono">${escapeHtml(m.branch || '-')}</span></div>
                <div><span class="text-secondary">Worktree:</span> <span class="font-mono">${escapeHtml(m.worktree || '-')}</span></div>
                <div><span class="text-secondary">Task:</span> ${escapeHtml(m.task || '-')}</div>
                <div><span class="text-secondary">Source File:</span> <span class="font-mono">${escapeHtml(m.sourceFile || '-')}</span></div>
                <div><span class="text-secondary">Source Commit:</span> <span class="font-mono">${escapeHtml(m.sourceCommit || '-')}</span></div>
                <div><span class="text-secondary">Source Session:</span> <span class="font-mono">${escapeHtml(m.sourceSession || '-')}</span></div>
                <div><span class="text-secondary">Source Message:</span> <span class="font-mono">${escapeHtml(m.sourceMessage || '-')}</span></div>
              </div>
            </div>
            <div>
              <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;">经验内容</h3>
              <div class="code-view">${escapeHtml(m.content || '')}</div>
            </div>
          `;
        }
      });
    });
  }

  function getMemoryStateBadge(stateStr) {
    const s = (stateStr || '').toLowerCase();
    switch (s) {
      case 'active':
        return '<span class="status-badge status-sage">生效中</span>';
      case 'candidate':
        return '<span class="status-badge status-amber">待审候选</span>';
      case 'superseded':
        return '<span class="status-badge status-neutral">已替代</span>';
      case 'archived':
        return '<span class="status-badge status-neutral">已归档</span>';
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(stateStr || '未知')}</span>`;
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
        <label class="form-label">标题</label>
        <input type="text" id="mem-title" class="form-input" value="${escapeHtml(initial.title || '')}" placeholder="简明工程经验标题">
      </div>
      <div class="form-group">
        <label class="form-label">内容</label>
        <textarea id="mem-content" class="form-textarea" placeholder="详细经验记录、约定或上下文">${escapeHtml(initial.content || '')}</textarea>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">类型</label>
          <select id="mem-type" class="form-select">
            ${validTypes.map(t => `<option value="${t}" ${((initial.type || 'fact').toLowerCase() === t) ? 'selected' : ''}>${t}</option>`).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">作用域</label>
          <select id="mem-scope" class="form-select">
            ${validScopes.map(s => `<option value="${s}" ${((initial.scope || 'project').toLowerCase() === s) ? 'selected' : ''}>${s}</option>`).join('')}
          </select>
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">关联项目</label>
          <select id="mem-project" class="form-select">
            <option value="">(全局通用)</option>
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}" ${(initial.project === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">状态</label>
          <select id="mem-state" class="form-select" ${isEdit ? 'disabled' : ''}>
            <option value="candidate" ${(initial.state || 'candidate').toLowerCase() === 'candidate' ? 'selected' : ''}>待审候选</option>
            <option value="active" ${(initial.state || '').toLowerCase() === 'active' ? 'selected' : ''}>生效中</option>
            <option value="superseded" ${(initial.state || '').toLowerCase() === 'superseded' ? 'selected' : ''}>已替代</option>
            <option value="archived" ${(initial.state || '').toLowerCase() === 'archived' ? 'selected' : ''}>已归档</option>
          </select>
          ${isEdit ? '<div style="font-size: 10px; color: var(--text-secondary); margin-top: 2px;">编辑已存记录不可直接修改生命周期状态。请在列表中使用「设为生效 / 替代 / 归档」按钮进行状态流转。</div>' : ''}
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">分支 (Branch)</label>
          <input type="text" id="mem-branch" class="form-input" value="${escapeHtml(initial.branch || '')}" placeholder="main / feature">
        </div>
        <div class="form-group">
          <label class="form-label">工作树 (Worktree)</label>
          <input type="text" id="mem-worktree" class="form-input" value="${escapeHtml(initial.worktree || '')}" placeholder="worktree 路径或名称">
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">任务 (Task)</label>
          <input type="text" id="mem-task" class="form-input" value="${escapeHtml(initial.task || '')}" placeholder="子任务或工单号">
        </div>
        <div class="form-group">
          <label class="form-label">来源会话 (Source Session)</label>
          <input type="text" id="mem-src-session" class="form-input" value="${escapeHtml(initial.sourceSession || '')}" placeholder="sess-xxx">
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">来源消息 (Source Message)</label>
          <input type="text" id="mem-src-msg" class="form-input" value="${escapeHtml(initial.sourceMessage || '')}" placeholder="m-xxx">
        </div>
        <div class="form-group">
          <label class="form-label">来源 Commit</label>
          <input type="text" id="mem-src-commit" class="form-input" value="${escapeHtml(initial.sourceCommit || '')}" placeholder="git commit sha">
        </div>
      </div>
      <div class="form-group">
        <label class="form-label">来源文件 (Source File)</label>
        <input type="text" id="mem-src-file" class="form-input" value="${escapeHtml(initial.sourceFile || '')}" placeholder="relative/path/to/file">
      </div>
    `;

    openModal(isEdit ? '编辑工程 Memory' : '创建工程 Memory', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-mem">取消</button>
      <button class="btn btn-primary" id="btn-save-mem">保存 Memory</button>
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
        showToast('标题与内容不能为空', 'error');
        return;
      }
      if (scope !== 'global' && !project) {
        showToast('非全局作用域必须指定所属项目', 'error');
        return;
      }
      if (scope === 'branch' && !branch) {
        showToast('当作用域为 branch 时，分支 (Branch) 字段必填', 'error');
        return;
      }
      if (scope === 'worktree' && !worktree) {
        showToast('当作用域为 worktree 时，工作树 (Worktree) 字段必填', 'error');
        return;
      }
      if (scope === 'task' && !task) {
        showToast('当作用域为 task 时，任务 (Task) 字段必填', 'error');
        return;
      }
      if (scope === 'session' && !sourceSession) {
        showToast('当作用域为 session 时，来源会话 (Source Session) 字段必填', 'error');
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
        showToast('Memory 保存成功');
        closeModal();
        await refreshDashboard(true, true);
      } catch (err) {
        showToast('保存失败: ' + err.message, 'error');
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
      <p style="font-size: 12px; color: var(--text-secondary); margin-bottom: 12px; line-height: 1.6;">
        以新条目替代旧条目：旧经验 <strong>${escapeHtml(oldTitle)}</strong> 将被原子标记为 <strong>superseded</strong>，由所选新条目生效 (active) 并继承替代关系。
      </p>
      ${eligibleReplacements.length === 0 ? `
        <div class="alert-banner alert-warning" style="margin-bottom: 12px; line-height: 1.6;">
          同项目内暂无可用的替代条目（需为 candidate 候选或 active 状态）。<br>
          若无需承接关系，可直接通过右侧抽屉面板将旧条目操作为「归档 (Archive)」。
        </div>
      ` : `
        <div class="form-group">
          <label class="form-label">选择承接生效的新条目 (Replacement Memory)</label>
          <select id="mem-supersede-target" class="form-select">
            <option value="">-- 请选择同项目新条目 --</option>
            ${eligibleReplacements.map(m => `
              <option value="${escapeHtml(m.id)}">${escapeHtml(m.title)} (${escapeHtml(m.id.substring(0, 8))}) [${escapeHtml(m.state || 'active')}]</option>
            `).join('')}
          </select>
        </div>
      `}
    `;

    openModal('替代 Memory 条目', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-supersede">取消</button>
      ${eligibleReplacements.length > 0 ? '<button class="btn btn-primary" id="btn-confirm-supersede">确认由新条目替代</button>' : ''}
    `);

    document.getElementById('btn-cancel-supersede').addEventListener('click', closeModal);
    const confirmBtn = document.getElementById('btn-confirm-supersede');
    if (confirmBtn) {
      confirmBtn.addEventListener('click', async () => {
        const replacementId = document.getElementById('mem-supersede-target').value;
        if (!replacementId) {
          showToast('请选择替代新条目', 'error');
          return;
        }
        try {
          // Atomically activate replacement B and mark A as superseded
          await callBridge('memory.transition', {
            id: replacementId,
            state: 'active',
            supersedes: memoryId
          });
          showToast(`已由新条目成功替代旧经验 [${oldTitle}]`);
          closeModal();
          await refreshDashboard(true, true);
        } catch (err) {
          showToast('替代操作失败: ' + err.message, 'error');
        }
      });
    }
  }

  function openRecallModal() {
    const modalBody = `
      <div class="form-group">
        <label class="form-label">查询关键词 / 任务上下文</label>
        <input type="text" id="recall-query" class="form-input" placeholder="例如：数据库迁移规范、构建指令、API 安全约定">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">作用域项目</label>
          <select id="recall-project" class="form-select">
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}">${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">Token 预算限制 (保守估算)</label>
          <select id="recall-budget" class="form-select">
            <option value="500">500 Tokens (保守估算)</option>
            <option value="1000" selected>1,000 Tokens (保守估算)</option>
            <option value="2000">2,000 Tokens (保守估算)</option>
            <option value="4000">4,000 Tokens (保守估算)</option>
          </select>
        </div>
      </div>
      <details style="margin-top: 8px; margin-bottom: 8px; font-size: 12px; color: var(--text-secondary);">
        <summary style="cursor: pointer; user-select: none; font-weight: 500;">高级上下文参数 (可选：Branch, Worktree, Task, SessionId)</summary>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;">Branch 分支</label>
            <input type="text" id="recall-branch" class="form-input" style="font-size: 12px;" placeholder="例如：main, feature/v2">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;">Worktree 路径</label>
            <input type="text" id="recall-worktree" class="form-input" style="font-size: 12px;" placeholder="例如：/path/to/worktree">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;">Task 任务标识</label>
            <input type="text" id="recall-task" class="form-input" style="font-size: 12px;" placeholder="例如：task-123">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 12px;">Session ID 会话标识</label>
            <input type="text" id="recall-session-id" class="form-input" style="font-size: 12px;" placeholder="例如：sess-uuid">
          </div>
        </div>
      </details>
      <div id="recall-results-area" style="margin-top: 10px; max-height: 200px; overflow-y: auto;"></div>
    `;

    openModal('Recall 预算召回测试', modalBody, `
      <button class="btn btn-secondary" id="btn-close-recall">关闭</button>
      <button class="btn btn-primary" id="btn-do-recall">执行 Recall</button>
    `);

    document.getElementById('btn-close-recall').addEventListener('click', closeModal);
    document.getElementById('btn-do-recall').addEventListener('click', async () => {
      const query = document.getElementById('recall-query').value.trim();
      const project = document.getElementById('recall-project').value;
      const budget = parseInt(document.getElementById('recall-budget').value, 10);
      const resultsArea = document.getElementById('recall-results-area');

      if (!query) {
        showToast('请输入查询内容', 'error');
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

      resultsArea.innerHTML = '<div class="text-secondary" style="font-size: 11px;">正在召回...</div>';

      try {
        const res = await callBridge('recall', recallPayload);
        const items = (res && res.items) || [];
        const used = (res && res.usedTokens) || 0;

        resultsArea.innerHTML = `
          <div style="margin-bottom: 6px; font-size: 11px; display: flex; justify-content: space-between;">
            <span>匹配到 <strong>${items.length}</strong> 条 Active 记忆</span>
            <span class="font-mono">已用估算 Token: <strong>${used}</strong> / ${budget}</span>
          </div>
          <div style="display: flex; flex-direction: column; gap: 6px;">
            ${items.length === 0 ? '<div style="font-size: 11px; color: var(--text-muted);">未召回到符合条件的 Active 条目</div>' : ''}
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
        <span class="text-secondary" style="font-size: 12px;">本地知识库文档 (${library.length}) · 支持私密标记（私密条目仅人工搜索可见，排除 Agent 检索）</span>
        <button id="btn-add-library" class="btn btn-primary btn-sm">+ 添加文档 / 知识</button>
      </div>

      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th>标题 / 名称</th>
              <th>项目</th>
              <th>私密属性</th>
              <th>来源 (Source)</th>
              <th style="text-align: right; width: 100px;">操作</th>
            </tr>
          </thead>
          <tbody>
            ${library.length === 0 ? '<tr><td colspan="5" style="text-align: center; color: var(--text-muted); padding: 24px;">暂无知识库条目</td></tr>' : ''}
            ${library.map(lib => `
              <tr>
                <td><strong>${escapeHtml(lib.title)}</strong></td>
                <td><span class="code-badge">${escapeHtml(lib.project ? lib.project.split('/').pop() : '全局')}</span></td>
                <td>
                  ${lib.private ? '<span class="status-badge status-amber">🔒 私密 (排除 Agent)</span>' : '<span class="status-badge status-neutral">公开 (可检索)</span>'}
                </td>
                <td style="font-size: 11px; font-family: var(--font-mono); color: var(--text-muted);">
                  ${escapeHtml(lib.url || lib.path || (lib.content ? lib.content.substring(0, 40) + '...' : '-'))}
                </td>
                <td style="text-align: right;">
                  <button class="btn btn-secondary btn-sm btn-view-library" data-id="${escapeHtml(lib.id)}">查看</button>
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
          openDrawer(lib.title || '知识库条目', lib.id);
          document.getElementById('drawer-content').innerHTML = `
            <div class="card">
              <div class="card-header">
                <span class="card-title">基本信息</span>
                ${lib.private ? '<span class="status-badge status-amber">🔒 私密</span>' : '<span class="status-badge status-neutral">公开</span>'}
              </div>
              <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
                <div><span class="text-secondary">项目:</span> ${escapeHtml(lib.project || '全局')}</div>
                <div><span class="text-secondary">创建时间:</span> ${formatTime(lib.createdAt)}</div>
              </div>
              ${lib.path ? `<div style="margin-top: 6px; font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">文件路径: ${escapeHtml(lib.path)}</div>` : ''}
              ${lib.url ? `<div style="margin-top: 6px; font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">URL: ${escapeHtml(lib.url)}</div>` : ''}
            </div>
            <div>
              <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;">文档内容</h3>
              <div class="code-view">${escapeHtml(lib.content || '(外部文件或 URL 引用)')}</div>
            </div>
          `;
        }
      });
    });
  }

  function openAddLibraryModal() {
    const modalBody = `
      <div class="form-group">
        <label class="form-label">来源类型 (Source Type)</label>
        <select id="lib-source-type" class="form-select">
          <option value="content">直接输入文本内容 (Text)</option>
          <option value="path">本地文件路径 (Local File Path)</option>
          <option value="url">网络文档链接 (Remote URL)</option>
        </select>
      </div>
      <div class="form-group">
        <label class="form-label">文档标题</label>
        <input type="text" id="lib-title" class="form-input" placeholder="输入知识文档标题">
      </div>
      <div class="form-group">
        <label class="form-label">所属项目</label>
        <select id="lib-project" class="form-select">
          <option value="">全局知识库</option>
          ${state.registeredProjects.map(p => `
            <option value="${escapeHtml(p.path || p.id)}">${escapeHtml(p.title || p.path)}</option>
          `).join('')}
        </select>
      </div>
      <div class="form-group" id="lib-group-content">
        <label class="form-label">文本内容</label>
        <textarea id="lib-content" class="form-textarea" placeholder="直接粘贴工程指南、接口说明或架构设计"></textarea>
      </div>
      <div class="form-group hidden" id="lib-group-path">
        <label class="form-label">本地绝对路径</label>
        <input type="text" id="lib-path" class="form-input font-mono" placeholder="/path/to/document.md">
      </div>
      <div class="form-group hidden" id="lib-group-url">
        <label class="form-label">文档 URL</label>
        <input type="url" id="lib-url" class="form-input font-mono" placeholder="https://example.com/docs">
      </div>
      <div class="form-group">
        <label class="form-checkbox-label">
          <input type="checkbox" id="lib-private" checked>
          <span>设为私密 (Private)：默认勾选。仅人工搜索可见，排除 Agent 自动检索与 MCP 以保护机密</span>
        </label>
      </div>
    `;

    openModal('添加知识库条目', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-lib">取消</button>
      <button class="btn btn-primary" id="btn-save-lib">保存知识库</button>
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
        showToast('标题不能为空', 'error');
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
        showToast('知识库条目已添加');
        closeModal();
        await refreshDashboard(true, true);
      } catch (e) {
        showToast('添加失败: ' + e.message, 'error');
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
      if (countSpan) countSpan.textContent = `共 ${artifacts.length} 项 MCP 配置`;

      if (artifacts.length === 0) {
        container.innerHTML = `
          <div class="empty-state" style="padding: 24px 0;">
            <div class="empty-state-title">未检测到 MCP 配置文件</div>
            <div class="empty-state-desc">在当前项目根目录（如 .mcp.json、.cursor/mcp.json）或全局配置中放置 MCP 配置文件，Vela 会自动扫描并展示。</div>
          </div>
        `;
        return;
      }

      container.innerHTML = `
        <div class="table-wrapper">
          <table class="data-table">
            <thead>
              <tr>
                <th>标题 / 标识</th>
                <th>Provider / 作用域</th>
                <th>估算 Tokens</th>
                <th>哈希 (SHA256)</th>
                <th>诊断</th>
                <th style="text-align: right; width: 140px;">操作</th>
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
                      ? `<span class="status-badge status-amber">${a.diagnostics.length} 项警告</span>`
                      : '<span class="status-badge status-sage">✓ 正常</span>'}
                  </td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-preview-artifact" data-id="${escapeHtml(a.id)}">预览</button>
                    ${a.path ? `<button class="btn btn-ghost btn-sm btn-reveal-path" data-path="${escapeHtml(a.path)}">定位</button>` : ''}
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
            openDrawer(art.title || 'MCP 配置详情', art.path);
            const drawerContent = document.getElementById('drawer-content');
            if (drawerContent) {
              drawerContent.innerHTML = `
                <div class="card">
                  <div class="card-header"><span class="card-title">基本信息</span></div>
                  <div style="font-size: 12px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                    <div><span class="text-secondary">类型:</span> ${escapeHtml(art.type || 'mcp')}</div>
                    <div><span class="text-secondary">Provider:</span> ${escapeHtml(art.provider || '-')}</div>
                    <div><span class="text-secondary">Token 估算:</span> ${escapeHtml(String(art.tokens || '-'))}</div>
                    <div><span class="text-secondary">Hash:</span> <span class="font-mono">${escapeHtml(art.hash || '-')}</span></div>
                  </div>
                  <div style="margin-top: 8px; font-size: 12px; font-family: var(--font-mono); color: var(--text-muted);">路径: ${escapeHtml(art.path || '-')}</div>
                </div>
                <div>
                  <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;">只读内容预览</h3>
                  <div class="code-view">${escapeHtml(art.content || '(无内容)')}</div>
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
            showToast('定位失败: ' + e.message, 'error');
          }
        });
      });
    }

    target.innerHTML = `
      <div class="card" style="margin-bottom: 20px;">
        <div class="card-header">
          <span class="card-title">Vela MCP 本地服务 (Model Context Protocol)</span>
          <span class="status-badge status-sage">stdio 支持</span>
        </div>
        <p style="font-size: 12px; color: var(--text-secondary); margin-bottom: 12px;">
          Vela 提供官方标准 stdio MCP 服务，使 Claude Desktop、Cursor、Codex 等编码智能体能够安全、按需检索经过验证的本地工程上下文。
        </p>

        <div class="alert-banner alert-info" style="margin-bottom: 12px;">
          <span>
            <strong>安全约束：</strong>MCP 协议默认以只读模式运行，严格按项目隔离作用域，并且<strong>始终完全排除私密 (Private) 知识库</strong>。执行写操作与应用变更永不暴露给 MCP。
          </span>
        </div>

        <h4 style="font-size: 12px; font-weight: 600; margin-bottom: 6px;">Claude Desktop / Cursor 配置示例</h4>
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
          <h3 style="font-size: 13px; font-weight: 600; margin: 0;">已扫描的 MCP 配置文件</h3>
          <span id="mcp-scanned-count" class="text-secondary" style="font-size: 12px;">共 ${mcpArtifacts.length} 项 MCP 配置</span>
        </div>
        <p style="font-size: 12px; color: var(--text-secondary); margin-top: 4px;">
          项目或全局环境中的 MCP 配置文件 (.mcp.json, .cursor/mcp.json) · 本地只读预览与定位
        </p>
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
    const thisGen = renderGeneration;
    const thisPage = state.currentPage;
    const thisScope = state.currentProject;

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>用量追踪</h1>
          <p>本地会话日志观察到的 Token 消耗与模型调用分布 · 100% 本地分析</p>
        </div>
      </div>

      <div class="alert-banner alert-info" style="margin-bottom: 14px;">
        <span>* 观察声明：本页面展示的 Token 统计源自本地会话日志观察值，仅供工程参考，非云端计费账单。</span>
      </div>

      <div class="stat-grid" id="usage-stat-grid">
        <div class="stat-card">
          <div class="stat-label">总观察 Token</div>
          <div class="stat-value" id="usage-total-tokens">-</div>
          <div class="stat-sub">Input + Output</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">总观察会话数</div>
          <div class="stat-value" id="usage-total-sessions">-</div>
          <div class="stat-sub">本地已收录会话</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">活跃 Provider</div>
          <div class="stat-value" id="usage-provider-count">-</div>
          <div class="stat-sub">已连接智能体工具</div>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <span class="card-title">Provider 用量分布</span>
        </div>
        <div class="table-wrapper" style="margin-bottom: 0;">
          <table class="data-table">
            <thead>
              <tr>
                <th>Provider</th>
                <th>输入 Tokens</th>
                <th>输出 Tokens</th>
                <th>总 Tokens</th>
                <th>会话数</th>
                <th>云端额度状态</th>
              </tr>
            </thead>
            <tbody id="usage-provider-tbody"></tbody>
          </table>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title">近期每日 Token 趋势</span>
        </div>
        <div id="usage-daily-container"></div>
      </div>
    `;

    try {
      const usage = await callBridge('usage.get', state.currentProject ? { project: state.currentProject } : {});
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(container)) return;

      if (usage) {
        document.getElementById('usage-total-tokens').textContent = (usage.totalTokens != null) ? formatNumber(usage.totalTokens) : '未提供';
        document.getElementById('usage-total-sessions').textContent = (usage.sessionCount != null) ? formatNumber(usage.sessionCount) : '未提供';

        const providers = usage.providers || [];
        document.getElementById('usage-provider-count').textContent = providers.length;

        const tbody = document.getElementById('usage-provider-tbody');
        if (providers.length === 0) {
          tbody.innerHTML = '<tr><td colspan="6" style="text-align:center; color:var(--text-muted); padding:20px;">未发现本地日志 Token 数据</td></tr>';
        } else {
          tbody.innerHTML = providers.map(p => `
            <tr>
              <td><strong>${escapeHtml(p.provider)}</strong></td>
              <td class="font-mono">${(p.inputTokens != null) ? formatNumber(p.inputTokens) : '未提供'}</td>
              <td class="font-mono">${(p.outputTokens != null) ? formatNumber(p.outputTokens) : '未提供'}</td>
              <td class="font-mono"><strong>${(p.totalTokens != null) ? formatNumber(p.totalTokens) : '未提供'}</strong></td>
              <td>${(p.sessionCount != null) ? formatNumber(p.sessionCount) : '未提供'}</td>
              <td>
                <span class="status-badge status-neutral">${p.quotaAvailable ? escapeHtml(p.quota) : '未提供'}</span>
              </td>
            </tr>
          `).join('');
        }

        const daily = usage.daily || [];
        const dailyCont = document.getElementById('usage-daily-container');
        if (daily.length === 0) {
          dailyCont.innerHTML = '<div style="font-size:11px; color:var(--text-muted); padding:10px 0;">无每日历史数据</div>';
        } else {
          const maxTokens = Math.max(...daily.map(d => d.tokens || 0), 1);
          dailyCont.innerHTML = `
            <div style="display: flex; align-items: flex-end; gap: 8px; height: 100px; padding: 10px 0; border-bottom: 1px solid var(--border-color);">
              ${daily.slice(-14).map(d => {
                const heightPct = Math.min(100, Math.max(10, Math.round(((d.tokens || 0) / maxTokens) * 100)));
                return `
                  <div style="flex: 1; display: flex; flex-direction: column; align-items: center; gap: 4px;" title="${escapeHtml(d.date)}: ${formatNumber(d.tokens)} Tokens">
                    <div style="width: 100%; height: ${heightPct}%; background: var(--text-main); border-radius: 2px 2px 0 0;"></div>
                    <span style="font-size: 9px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(d.date.substring(5))}</span>
                  </div>
                `;
              }).join('')}
            </div>
          `;
        }
      }
    } catch (err) {
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(container)) return;
      const grid = document.getElementById('usage-stat-grid');
      if (grid) {
        grid.innerHTML = `
          <div class="alert-banner alert-danger">无法加载用量数据：${escapeHtml(err.message)}</div>
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
          <h1>调优建议</h1>
          <p>从反复出现的会话模式中提炼改进方案 · 严格证据阈值与原子回滚</p>
        </div>
        <div class="page-actions">
          <button id="btn-run-analysis" class="btn btn-primary btn-sm">分析工程证据</button>
        </div>
      </div>

      <div class="card" style="background: var(--bg-subtle);">
        <div style="font-size: 12px; line-height: 1.5; color: var(--text-secondary);">
          <strong>确定性提升规则：</strong>
          Vela 仅在同一模式于<strong>至少 2 个独立会话中出现 3 次以上信号</strong>时才形成建议。
          没有虚假 AI 评分；所有调优建议必须在本地人工审查 Diff 并显式确认后，方可原子写入项目。
        </div>
      </div>

      <div class="table-wrapper" style="margin-top: 14px;">
        <table class="data-table">
          <thead>
            <tr>
              <th>建议标题</th>
              <th>载体 (Carrier)</th>
              <th>证据信号 (Evidence)</th>
              <th>影响 Context</th>
              <th>状态</th>
              <th style="text-align: right; width: 220px;">操作</th>
            </tr>
          </thead>
          <tbody id="improve-table-tbody">
            ${suggestions.length === 0 ? '<tr><td colspan="6" style="text-align: center; color: var(--text-muted); padding: 32px;">暂无达到阈值的调优建议。点击“分析工程证据”扫描当前项目日志。</td></tr>' : ''}
            ${suggestions.map(sug => {
              const st = (sug.state || 'pending').toLowerCase();
              return `
                <tr>
                  <td><strong>${escapeHtml(sug.title)}</strong></td>
                  <td><span class="code-badge">${escapeHtml(sug.carrier || 'AGENTS.md')}</span></td>
                  <td><span class="font-mono">${sug.evidence ? sug.evidence.length : 0} 次信号</span></td>
                  <td><span class="font-mono">${sug.contextTokens ? '~' + escapeHtml(String(sug.contextTokens)) + ' tokens' : '-'}</span></td>
                  <td>${getImproveStateBadge(st)}</td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-preview-diff" data-id="${escapeHtml(sug.id)}">审查 Diff</button>
                    ${st === 'applied' ? `<button class="btn btn-ghost btn-sm btn-undo-sug" data-id="${escapeHtml(sug.id)}">撤销</button>` : ''}
                    ${st !== 'applied' && st !== 'dismissed' ? `<button class="btn btn-ghost btn-sm btn-dismiss-sug" data-id="${escapeHtml(sug.id)}">忽略</button>` : ''}
                  </td>
                </tr>
              `;
            }).join('')}
          </tbody>
        </table>
      </div>
    `;

    document.getElementById('btn-run-analysis').addEventListener('click', async () => {
      try {
        showToast('正在分析会话工程证据...');
        const result = await callBridge('improve.analyze', state.currentProject ? { project: state.currentProject } : {});
        const count = (result && result.suggestions && result.suggestions.length) || 0;
        showToast(`分析完成，提炼出 ${count} 条达到阈值的建议`);
        await refreshDashboard(true, true);
      } catch (e) {
        showToast('分析失败: ' + e.message, 'error');
      }
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
          showToast('已原子回滚建议变更');
          await refreshDashboard(true, true);
        } catch (e) {
          showToast('撤销失败: ' + e.message, 'error');
        }
      });
    });

    container.querySelectorAll('.btn-dismiss-sug').forEach(btn => {
      btn.addEventListener('click', async () => {
        const id = btn.getAttribute('data-id');
        try {
          await callBridge('improve.dismiss', { id });
          showToast('已忽略该建议');
          await refreshDashboard(true, true);
        } catch (e) {
          showToast('忽略失败: ' + e.message, 'error');
        }
      });
    });
  }

  function getImproveStateBadge(st) {
    const s = (st || '').toLowerCase();
    switch (s) {
      case 'applied':
        return '<span class="status-badge status-sage">✓ 已应用</span>';
      case 'pending':
      case 'ready':
        return '<span class="status-badge status-amber">待审查</span>';
      case 'dismissed':
        return '<span class="status-badge status-neutral">已忽略</span>';
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(st || '待审查')}</span>`;
    }
  }

  async function openImprovePreviewDrawer(suggestionId) {
    state.selectedSuggestionId = suggestionId;
    openDrawer('加载 Diff 详情...', '调优建议');

    try {
      const previewObj = await callBridge('improve.preview', { id: suggestionId });
      if (!previewObj) throw new Error('未获取到预览数据');

      setDrawerTitle(previewObj.title || '建议详情', suggestionId ? `建议 · ${suggestionId.substring(0, 8)}` : '调优建议');
      const isApplied = (previewObj.state || '').toLowerCase() === 'applied';

      setDrawerCustomActions(`
        ${!isApplied ? `<button id="btn-drawer-apply-sug" class="btn btn-primary btn-sm">确认应用 (Apply)</button>` : `<button id="btn-drawer-undo-sug" class="btn btn-danger btn-sm">撤销应用 (Undo)</button>`}
      `);

      if (document.getElementById('btn-drawer-apply-sug')) {
        document.getElementById('btn-drawer-apply-sug').addEventListener('click', () => {
          openConfirmApplyModal(previewObj);
        });
      }
      if (document.getElementById('btn-drawer-undo-sug')) {
        document.getElementById('btn-drawer-undo-sug').addEventListener('click', async () => {
          try {
            await callBridge('improve.undo', { id: suggestionId });
            showToast('已原子回滚变更');
            closeDrawer();
            await refreshDashboard(true, true);
          } catch (e) {
            showToast('撤销失败: ' + e.message, 'error');
          }
        });
      }

      // Authoritative preview shape: preview: [{ path, before, beforeHash, content, afterHash, delete }]
      const previewList = previewObj.preview || previewObj.operations || [];
      const evidenceList = previewObj.evidence || [];
      const drawerBody = document.getElementById('drawer-content');

      drawerBody.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title">元数据</span>
            ${getImproveStateBadge(previewObj.state)}
          </div>
          <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
            <div><span class="text-secondary">目标载体:</span> <strong>${escapeHtml(previewObj.carrier || 'AGENTS.md')}</strong></div>
            <div><span class="text-secondary">影响 Tokens:</span> ${previewObj.contextTokens ? '~' + escapeHtml(String(previewObj.contextTokens)) : '-'}</div>
          </div>
        </div>

        <div>
          <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;">文件变更 Diff (${previewList.length})</h3>
          <div style="display: flex; flex-direction: column; gap: 10px;">
            ${previewList.map(item => `
              <div class="card" style="margin-bottom: 0; padding: 10px 12px;">
                <div style="font-size: 11px; font-family: var(--font-mono); font-weight: 600; margin-bottom: 6px;">
                  ${escapeHtml(item.path || '目标文件')}
                  ${item.delete ? '<span class="status-badge status-red" style="margin-left: 6px;">删除</span>' : ''}
                </div>
                ${renderDiffView(item.before || '', item.content || item.after || '')}
              </div>
            `).join('')}
          </div>
        </div>

        ${evidenceList.length > 0 ? `
          <div>
            <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 8px;">关联会话证据 (${evidenceList.length})</h3>
            <div style="display: flex; flex-direction: column; gap: 6px;">
              ${evidenceList.map(ev => `
                <div class="card" style="padding: 8px 10px; margin-bottom: 0;">
                  <div style="font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">
                    会话: ${escapeHtml(ev.sessionId || '-')} · 消息: ${escapeHtml(ev.messageId || '-')}
                  </div>
                  ${ev.quote ? `<div style="font-size: 11px; margin-top: 4px; color: var(--text-secondary); font-style: italic;">"${escapeHtml(ev.quote)}"</div>` : ''}
                </div>
              `).join('')}
            </div>
          </div>
        ` : ''}
      `;
    } catch (err) {
      setDrawerTitle('加载失败', '错误');
      document.getElementById('drawer-content').innerHTML = `
        <div class="alert-banner alert-danger">无法加载预览：${escapeHtml(err.message)}</div>
      `;
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
    const previewList = previewObj.preview || previewObj.operations || [];
    const modalBody = `
      <div class="alert-banner alert-warning">
        <span>注意：应用操作将对项目工作区文件执行原子写入。Vela 会在写入前校验基线哈希，并记录原子回滚日志。</span>
      </div>
      <p style="font-size: 12px; color: var(--text-main);">
        即将写入以下变更到 <strong>${escapeHtml(previewObj.carrier || '项目文件')}</strong>：
      </p>
      <ul style="padding-left: 18px; font-size: 11px; color: var(--text-secondary); margin-top: 6px;">
        ${previewList.map(op => `<li><code class="code-badge">${escapeHtml(op.path || '')}</code></li>`).join('')}
      </ul>
    `;

    openModal('确认应用调优建议', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-apply">取消</button>
      <button class="btn btn-primary" id="btn-confirm-apply">确认原子写入</button>
    `);

    document.getElementById('btn-cancel-apply').addEventListener('click', closeModal);
    document.getElementById('btn-confirm-apply').addEventListener('click', async () => {
      try {
        await callBridge('improve.apply', { id: previewObj.id });
        showToast('调优建议已成功应用');
        closeModal();
        closeDrawer();
        await refreshDashboard(true, true);
      } catch (err) {
        showToast('应用失败: ' + err.message, 'error');
      }
    });
  }

  // -------------------------------------------------------------------------
  // 6. LAB VIEW (Real backend schemas: results grouped by variant, summary, regression tab)
  // -------------------------------------------------------------------------
  function renderLabView(container) {
    const evals = (state.dashboard && state.dashboard.evals) || [];

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>对照实验</h1>
          <p>确定性命令对照评测 · 独立 Git Worktree 运行 · 真实退出状态与耗时</p>
        </div>
        <div class="page-actions">
          <button id="btn-new-lab" class="btn btn-primary btn-sm">+ 新建对照实验</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.labActiveTab === 'evals' ? 'active' : ''}" data-labtab="evals">实验列表 (${evals.length})</button>
        <button class="tab-btn ${state.labActiveTab === 'regression' ? 'active' : ''}" data-labtab="regression">回归分析</button>
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
          <strong>对照实验原则：</strong>
          Vela 实验在<strong>相同 Git HEAD</strong> 的独立 Worktree 中，分别挂载 Baseline 与 Candidate 配置，并执行完全相同的验证命令。
          命令执行需要经过 <strong>Inbox 审批</strong>后运行。评测器为真实退出码与执行耗时，杜绝主观模型打分。
        </div>
      </div>

      <div class="table-wrapper">
        <table class="data-table">
          <thead>
            <tr>
              <th>实验名称</th>
              <th>类别 (Kind)</th>
              <th>Baseline 通过率 / 耗时</th>
              <th>Candidate 通过率 / 耗时</th>
              <th>评测器</th>
              <th>运行状态</th>
              <th style="text-align: right; width: 140px;">操作</th>
            </tr>
          </thead>
          <tbody>
            ${evals.length === 0 ? '<tr><td colspan="7" style="text-align: center; color: var(--text-muted); padding: 32px;">暂无实验记录。点击“新建对照实验”以验证不同规约对构建/测试命令的实际影响。</td></tr>' : ''}
            ${evals.map(ev => {
              const st = (ev.state || 'pending_approval').toLowerCase();
              const isPending = (st === 'pending_approval');
              const baseSummary = ev.summary && ev.summary.baseline;
              const candSummary = ev.summary && ev.summary.candidate;

              const baseText = isPending ? '尚未运行' : (baseSummary ? `${(baseSummary.passRate * 100).toFixed(0)}% · ${Math.round(baseSummary.averageDurationMs || 0)}ms` : '-');
              const candText = isPending ? '尚未运行' : (candSummary ? `${(candSummary.passRate * 100).toFixed(0)}% · ${Math.round(candSummary.averageDurationMs || 0)}ms` : '-');

              return `
                <tr class="clickable-row" data-id="${escapeHtml(ev.id)}">
                  <td><strong>${escapeHtml(ev.title)}</strong></td>
                  <td><span class="code-badge">${escapeHtml(ev.evaluationKind || ev.kind || 'context')}</span></td>
                  <td><span class="font-mono" style="font-size: 11px;">${escapeHtml(baseText)}</span></td>
                  <td><span class="font-mono" style="font-size: 11px;">${escapeHtml(candText)}</span></td>
                  <td><span class="font-mono" style="font-size: 11px;">deterministic_command</span></td>
                  <td>${getEvalStateBadge(st)}</td>
                  <td style="text-align: right;">
                    <button class="btn btn-secondary btn-sm btn-lab-compare" data-id="${escapeHtml(ev.id)}">对照详情</button>
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

    target.innerHTML = `<div class="text-secondary" style="font-size: 12px; padding: 20px 0;">加载回归分析数据...</div>`;

    try {
      const reg = await callBridge('regression.list', state.currentProject ? { project: state.currentProject } : {});
      if (thisGen !== renderGeneration || state.currentPage !== thisPage || state.currentProject !== thisScope || !document.contains(target)) return;
      const comparisons = (reg && reg.workflowComparisons) || [];
      const evaluations = (reg && reg.evaluations) || [];

      const formatPerSide = (side) => {
        if (!side) return '未提供';
        const runsText = `${side.runs ?? 0} 次运行`;
        const successRateText = (side.successRate !== null && side.successRate !== undefined)
          ? `${(side.successRate * 100).toFixed(1)}%`
          : '未提供';
        const meanRuntimeText = (side.meanRuntimeMs !== null && side.meanRuntimeMs !== undefined)
          ? `${Math.round(side.meanRuntimeMs)}ms`
          : '未提供';
        return `${runsText} · 通过率 ${successRateText} · 均耗时 ${meanRuntimeText}`;
      };

      target.innerHTML = `
        <div class="card" style="margin-bottom: 14px;">
          <div class="card-header">
            <span class="card-title">工作流回归比对 (Workflow Comparisons)</span>
            <span class="status-badge status-neutral">历史运行的输入与环境可能不同</span>
          </div>
          ${comparisons.length === 0 ? '<div style="font-size: 12px; color: var(--text-muted); padding: 8px 0;">暂无工作流回归记录</div>' : `
            <div class="table-wrapper" style="margin-bottom: 0;">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>工作流 ID</th>
                    <th>基线 vs 候选版本</th>
                    <th>基线表现 (Baseline)</th>
                    <th>候选表现 (Candidate)</th>
                    <th>因果性 (Causality)</th>
                  </tr>
                </thead>
                <tbody>
                  ${comparisons.map(c => `
                    <tr>
                      <td><strong>${escapeHtml(c.workflowId || '-')}</strong></td>
                      <td><span class="code-badge">v${escapeHtml(String(c.baselineVersion ?? '-'))} vs v${escapeHtml(String(c.candidateVersion ?? '-'))}</span></td>
                      <td style="font-size: 11px;">${escapeHtml(formatPerSide(c.baseline))}</td>
                      <td style="font-size: 11px;">${escapeHtml(formatPerSide(c.candidate))}</td>
                      <td style="font-size: 11px; color: var(--text-muted);">历史运行的输入与环境可能不同</td>
                    </tr>
                  `).join('')}
                </tbody>
              </table>
            </div>
          `}
        </div>

        <div class="card">
          <div class="card-header">
            <span class="card-title">历史评测回归汇总 (Evaluations Summary)</span>
            <span class="text-secondary" style="font-size: 11px;">点击评测行可查看基线与候选对照详情</span>
          </div>
          ${evaluations.length === 0 ? '<div style="font-size: 12px; color: var(--text-muted); padding: 8px 0;">暂无实验回归数据</div>' : `
            <div class="table-wrapper" style="margin-bottom: 0;">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>评测 ID</th>
                    <th>标题</th>
                    <th>类型</th>
                    <th>状态</th>
                    <th>耗时差 (runtimeDeltaMs)</th>
                    <th>成功率差 (successDelta)</th>
                    <th style="text-align: right; width: 90px;">操作</th>
                  </tr>
                </thead>
                <tbody>
                  ${evaluations.map(e => {
                    const sm = e.summary || {};
                    const runtimeDelta = (sm.runtimeDeltaMs !== undefined && sm.runtimeDeltaMs !== null)
                      ? `${sm.runtimeDeltaMs > 0 ? '+' : ''}${sm.runtimeDeltaMs}ms`
                      : '未提供';
                    const successDelta = (sm.successDelta !== undefined && sm.successDelta !== null)
                      ? `${sm.successDelta > 0 ? '+' : ''}${(sm.successDelta * 100).toFixed(1)}%`
                      : '未提供';
                    return `
                      <tr class="clickable-row btn-eval-row" data-id="${escapeHtml(e.id)}">
                        <td><span class="code-badge">${escapeHtml(e.id ? e.id.substring(0, 8) : '-')}</span></td>
                        <td><strong>${escapeHtml(e.title || '-')}</strong></td>
                        <td><span class="code-badge">${escapeHtml(e.evaluationKind || e.kind || 'context')}</span></td>
                        <td>${getEvalStateBadge(e.state)}</td>
                        <td class="font-mono">${escapeHtml(runtimeDelta)}</td>
                        <td class="font-mono">${escapeHtml(successDelta)}</td>
                        <td style="text-align: right;">
                          <button class="btn btn-secondary btn-sm btn-open-eval-compare" data-id="${escapeHtml(e.id)}">对照详情</button>
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
      target.innerHTML = `<div class="alert-banner alert-danger">无法获取回归分析数据: ${escapeHtml(err.message)}</div>`;
    }
  }

  function getEvalStateBadge(st) {
    const s = (st || '').toLowerCase();
    switch (s) {
      case 'completed':
        return '<span class="status-badge status-sage">✓ 已完成</span>';
      case 'pending_approval':
      case 'pending approval':
        return '<span class="status-badge status-amber">等待审批</span>';
      case 'running':
        return '<span class="status-badge status-amber">● 运行中</span>';
      case 'failed':
        return '<span class="status-badge status-red">失败</span>';
      case 'rejected':
        return '<span class="status-badge status-neutral">已拒绝</span>';
      default:
        return `<span class="status-badge status-neutral">${escapeHtml(st || '就绪')}</span>`;
    }
  }

  function openCreateLabModal() {
    const defaultBaseline = JSON.stringify({}, null, 2);
    const defaultCandidate = JSON.stringify({
      files: [
        {
          path: "AGENTS.md",
          content: "# Project Engineering Context\n- Run tests with npm test\n- Follow strict linting rules"
        }
      ]
    }, null, 2);

    const defaultCommand = JSON.stringify(["npm", "test"], null, 2);

    const modalBody = `
      <div class="form-group">
        <label class="form-label">实验标题</label>
        <input type="text" id="lab-title" class="form-input" placeholder="例如：添加 AGENTS.md 规约对单元测试通过率的影响" value="AGENTS.md 规约验证实验">
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">目标项目</label>
          <select id="lab-project" class="form-select">
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}">${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">实验类型 (Kind)</label>
          <select id="lab-kind" class="form-select">
            <option value="context">context (上下文文件对比)</option>
            <option value="memory">memory (Memory 规则配置对比)</option>
            <option value="workflow">workflow (工作流对比)</option>
          </select>
        </div>
      </div>

      <div class="form-group">
        <label class="form-label">
          <span>验证命令 (JSON 字符串数组)</span>
          <span class="form-help">例如 ["npm", "test"] 或 ["swift", "test"]</span>
        </label>
        <textarea id="lab-command" class="form-textarea code-editor" style="min-height: 48px;">${escapeHtml(defaultCommand)}</textarea>
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">Baseline 配置 (JSON 对象)</label>
          <textarea id="lab-baseline" class="form-textarea code-editor" style="min-height: 80px;">${escapeHtml(defaultBaseline)}</textarea>
        </div>
        <div class="form-group">
          <label class="form-label">Candidate 配置 (JSON 对象)</label>
          <textarea id="lab-candidate" class="form-textarea code-editor" style="min-height: 80px;">${escapeHtml(defaultCandidate)}</textarea>
        </div>
      </div>

      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">超时限制 (秒)</label>
          <input type="number" id="lab-timeout" class="form-input" value="60" min="5" max="600">
        </div>
        <div class="form-group">
          <label class="form-label">重复执行次数</label>
          <input type="number" id="lab-repetitions" class="form-input" value="1" min="1" max="5">
        </div>
      </div>
    `;

    openModal('新建 Worktree 对照实验', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-lab">取消</button>
      <button class="btn btn-primary" id="btn-save-lab">提交实验 (进入待审批)</button>
    `);

    document.getElementById('btn-cancel-lab').addEventListener('click', closeModal);
    document.getElementById('btn-save-lab').addEventListener('click', async () => {
      const title = document.getElementById('lab-title').value.trim();
      const project = document.getElementById('lab-project').value;
      const kind = document.getElementById('lab-kind').value;
      const timeoutSeconds = parseInt(document.getElementById('lab-timeout').value, 10) || 60;
      const repetitions = parseInt(document.getElementById('lab-repetitions').value, 10) || 1;

      let commandArr = [];
      try {
        commandArr = JSON.parse(document.getElementById('lab-command').value);
        if (!Array.isArray(commandArr)) throw new Error('命令必须为 JSON 字符串数组');
      } catch (err) {
        showToast('验证命令格式错误: ' + err.message, 'error');
        return;
      }

      let baselineObj = {};
      try {
        baselineObj = JSON.parse(document.getElementById('lab-baseline').value);
        if (typeof baselineObj !== 'object' || Array.isArray(baselineObj) || baselineObj === null) {
          throw new Error('Baseline 必须为 JSON 对象');
        }
      } catch (err) {
        showToast('Baseline JSON 格式错误: ' + err.message, 'error');
        return;
      }

      let candidateObj = {};
      try {
        candidateObj = JSON.parse(document.getElementById('lab-candidate').value);
        if (typeof candidateObj !== 'object' || Array.isArray(candidateObj) || candidateObj === null) {
          throw new Error('Candidate 必须为 JSON 对象');
        }
      } catch (err) {
        showToast('Candidate JSON 格式错误: ' + err.message, 'error');
        return;
      }

      try {
        await callBridge('lab.run', {
          title,
          project,
          kind,
          command: commandArr,
          baseline: baselineObj,
          candidate: candidateObj,
          timeoutSeconds,
          repetitions
        });
        showToast('实验已创建并进入 Inbox 审批队列');
        closeModal();
        await refreshDashboard(true, true);
      } catch (err) {
        showToast('创建实验失败: ' + err.message, 'error');
      }
    });
  }

  async function openLabCompareDrawer(evalId) {
    state.selectedEvalId = evalId;
    openDrawer('加载对照评测详情...', '对照实验');

    try {
      const cmp = await callBridge('lab.compare', { id: evalId });
      if (!cmp) throw new Error('未获取到评测对照数据');

      setDrawerTitle(cmp.title || '实验对照结果', evalId ? `实验 · ${evalId.substring(0, 8)}` : '对照实验');
      const isPending = ((cmp.state || '').toLowerCase() === 'pending_approval');
      const results = cmp.results || [];
      const baselineRuns = results.filter(r => r.variant === 'baseline');
      const candidateRuns = results.filter(r => r.variant === 'candidate');
      const summary = cmp.summary || {};

      const drawerBody = document.getElementById('drawer-content');

      drawerBody.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title">基本信息</span>
            ${getEvalStateBadge(cmp.state)}
          </div>
          <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
            <div><span class="text-secondary">类型:</span> ${escapeHtml(cmp.evaluationKind || cmp.kind || 'context')}</div>
            <div><span class="text-secondary">评测器:</span> <span class="font-mono">deterministic_command</span></div>
            <div><span class="text-secondary">执行命令:</span> <span class="font-mono">${escapeHtml(Array.isArray(cmp.command) ? cmp.command.join(' ') : cmp.command || '-')}</span></div>
            <div><span class="text-secondary">Commit:</span> <span class="font-mono">${cmp.commit ? escapeHtml(cmp.commit.substring(0, 8)) : '-'}</span></div>
          </div>
        </div>

        ${isPending ? `
          <div class="empty-state">
            <div class="empty-state-title">实验等待审批 (Pending Approval)</div>
            <div class="empty-state-desc">该命令实验已进入 Inbox 待办列表。在工程师显式批准前，不会在 Worktree 中执行任何外部命令。</div>
          </div>
        ` : `
          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
            <div class="card" style="margin-bottom: 0;">
              <div class="card-header">
                <span class="card-title">Baseline 对照组</span>
                <span class="status-badge status-neutral">
                  ${summary.baseline ? `Pass: ${(summary.baseline.passRate * 100).toFixed(0)}%` : '-'}
                </span>
              </div>
              <div style="font-size: 12px; margin-bottom: 8px;">
                平均耗时: <strong>${summary.baseline ? Math.round(summary.baseline.averageDurationMs || 0) + 'ms' : '-'}</strong>
              </div>
              <div style="display: flex; flex-direction: column; gap: 8px; max-height: 200px; overflow-y: auto;">
                ${baselineRuns.map((r, i) => `
                  <div style="background: var(--bg-subtle); padding: 8px; border-radius: 4px; font-size: 12px;">
                    <div><strong>第 ${i + 1} 次</strong> · Exit: ${escapeHtml(String(r.exitCode))} · ${r.durationMs || 0}ms ${r.timedOut ? '(超时)' : ''}</div>
                    <div class="code-view" style="font-size: 12px; margin-top: 4px; max-height: 80px;">${escapeHtml(r.output || '(无输出)')}</div>
                  </div>
                `).join('')}
              </div>
            </div>

            <div class="card" style="margin-bottom: 0;">
              <div class="card-header">
                <span class="card-title">Candidate 候选组</span>
                <span class="status-badge status-sage">
                  ${summary.candidate ? `Pass: ${(summary.candidate.passRate * 100).toFixed(0)}%` : '-'}
                </span>
              </div>
              <div style="font-size: 12px; margin-bottom: 8px;">
                平均耗时: <strong>${summary.candidate ? Math.round(summary.candidate.averageDurationMs || 0) + 'ms' : '-'}</strong>
              </div>
              <div style="display: flex; flex-direction: column; gap: 8px; max-height: 200px; overflow-y: auto;">
                ${candidateRuns.map((r, i) => `
                  <div style="background: var(--bg-subtle); padding: 8px; border-radius: 4px; font-size: 12px;">
                    <div><strong>第 ${i + 1} 次</strong> · Exit: ${escapeHtml(String(r.exitCode))} · ${r.durationMs || 0}ms ${r.timedOut ? '(超时)' : ''}</div>
                    <div class="code-view" style="font-size: 12px; margin-top: 4px; max-height: 80px;">${escapeHtml(r.output || '(无输出)')}</div>
                  </div>
                `).join('')}
              </div>
            </div>
          </div>

          ${(summary.runtimeDeltaMs !== undefined || summary.successDelta !== undefined) ? `
            <div class="card" style="margin-top: 10px;">
              <div class="card-header"><span class="card-title">对照结论统计 (Summary Deltas)</span></div>
              <div style="font-size: 12px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                <div>耗时差异: <strong>${summary.runtimeDeltaMs !== undefined ? escapeHtml(String(summary.runtimeDeltaMs)) + 'ms' : '-'}</strong></div>
                <div>成功率变化: <strong>${summary.successDelta !== undefined ? escapeHtml(String(summary.successDelta)) : '-'}</strong></div>
              </div>
            </div>
          ` : ''}
        `}
      `;
    } catch (err) {
      setDrawerTitle('加载失败', '错误');
      document.getElementById('drawer-content').innerHTML = `
        <div class="alert-banner alert-danger">无法加载对比数据：${escapeHtml(err.message)}</div>
      `;
    }
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
      const projectBasename = projectPath ? (projectPath.split('/').filter(Boolean).pop() || projectPath) : '全局';

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

      const frozenTool = (typeof appr.tool === 'string' && appr.tool.trim()) ? appr.tool.trim() : '操作';
      const isFileOp = frozenTool.toLowerCase().includes('file') || frozenTool.toLowerCase().includes('write') || frozenTool.toLowerCase().includes('edit');

      return {
        projectBasename,
        projectPath,
        targetDisplay,
        commandDisplay,
        previewText,
        isFileOp,
        toolName: frozenTool
      };
    }

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>待办审批</h1>
          <p>写操作、脚本执行与对照实验的安全审查门禁 · 参数完全冻结，仅运行审批快照</p>
        </div>
      </div>

      ${pendingApprovals.length === 0 ? `
        <div class="empty-state">
          <div class="empty-state-title">当前无待执行操作</div>
          <div class="empty-state-desc">当工作流包含测试/写入步骤，或创建 Lab 实验时，待办审批将在此出现。审批通过前命令不会被执行。</div>
        </div>
      ` : `
        <div style="display: flex; flex-direction: column; gap: 14px;">
          ${pendingApprovals.map(appr => {
            const summary = getApprovalSummary(appr);
            return `
              <div class="card" style="margin-bottom: 0; padding: 16px 18px;">
                <div class="card-header" style="margin-bottom: 8px;">
                  <div>
                    <strong style="font-size: 14px;">${escapeHtml(appr.title || '操作执行申请')}</strong>
                    <span class="code-badge" style="margin-left: 6px;">${escapeHtml(summary.toolName)}</span>
                  </div>
                  <span class="status-badge status-amber">待审批</span>
                </div>

                ${appr.intent || appr.description ? `
                  <div style="font-size: 13px; color: var(--text-main); margin-bottom: 10px; line-height: 1.5;">
                    ${escapeHtml(appr.intent || appr.description)}
                  </div>
                ` : ''}

                <div style="font-size: 12px; color: var(--text-secondary); margin-bottom: 10px; display: flex; flex-direction: column; gap: 4px;">
                  <div><strong>所属项目:</strong> <span class="font-mono" title="${escapeHtml(summary.projectPath)}">${escapeHtml(summary.projectBasename)}</span></div>
                  ${summary.targetDisplay ? `
                    <div><strong>目标文件:</strong> <code class="code-badge font-mono">${escapeHtml(summary.targetDisplay)}</code></div>
                  ` : (summary.isFileOp ? `
                    <div><strong>目标文件:</strong> <span class="text-muted">未提供具体路径</span></div>
                  ` : '')}
                  ${summary.commandDisplay ? `
                    <div><strong>执行命令:</strong> <code class="code-badge font-mono">${escapeHtml(summary.commandDisplay)}</code></div>
                  ` : ''}
                </div>

                ${summary.previewText ? `
                  <div style="margin-bottom: 10px;">
                    <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 3px;">变更内容预览:</div>
                    <pre class="code-view" style="font-size: 11px; padding: 6px 8px; max-height: 64px; overflow: hidden; margin: 0; white-space: pre-wrap; word-break: break-all;">${escapeHtml(summary.previewText)}</pre>
                  </div>
                ` : ''}

                <details style="margin-bottom: 14px;">
                  <summary style="font-size: 12px; font-weight: 600; cursor: pointer; color: var(--text-secondary); user-select: none;">
                    查看冻结参数与快照哈希
                  </summary>
                  <div style="margin-top: 8px; font-size: 12px; color: var(--text-muted); font-family: var(--font-mono); margin-bottom: 6px;">
                    ${summary.projectPath ? `项目完整路径: ${escapeHtml(summary.projectPath)}<br>` : ''}
                    快照哈希: ${appr.snapshotHash ? escapeHtml(appr.snapshotHash) : '无'}
                  </div>
                  <div class="code-view" style="font-size: 12px; max-height: 160px; overflow-y: auto;">${escapeHtml(typeof appr.arguments === 'object' ? JSON.stringify(appr.arguments, null, 2) : appr.arguments || '{}')}</div>
                </details>

                <div style="display: flex; justify-content: flex-end; gap: 8px;">
                  <button class="btn btn-secondary btn-sm btn-reject-appr" data-id="${escapeHtml(appr.id)}" data-hash="${escapeHtml(appr.snapshotHash || '')}">拒绝</button>
                  <button class="btn btn-primary btn-sm btn-approve-appr" data-id="${escapeHtml(appr.id)}" data-hash="${escapeHtml(appr.snapshotHash || '')}">批准执行</button>
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
          showToast('已批准并触发执行');
          await refreshDashboard(true, true);
        } catch (err) {
          showToast('审批失败: ' + err.message, 'error');
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
          showToast('已拒绝该操作');
          await refreshDashboard(true, true);
        } catch (err) {
          showToast('操作失败: ' + err.message, 'error');
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
          <h1>设置</h1>
          <p>本地偏好设置 · 隐私声明 · 运行环境与存储路径</p>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <span class="card-title">系统通知</span>
          ${(state.systemInfo && state.systemInfo.notificationsSupported === false) ? '<span class="status-badge status-neutral">仅 .app 支持</span>' : ''}
        </div>

        <div style="display: flex; flex-direction: column; gap: 14px;">
          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-notifications" ${settings.notifications ? 'checked' : ''}>
            <div>
              <strong style="font-size: 13px;">桌面通知</strong>
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;">仅在开启后请求系统通知权限。通知由原生统一发布，默认关闭。</div>
            </div>
          </label>

          <fieldset id="sub-notifications-group" ${settings.notifications ? '' : 'disabled'} style="border: none; margin: 0; padding: 0 0 0 24px; display: flex; flex-direction: column; gap: 10px; ${settings.notifications ? '' : 'opacity: 0.5;'}">
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notif-sound" ${settings.notificationSound !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;">播放提示音</span>
                <div style="font-size: 12px; color: var(--text-secondary);">有新事件或通知时播放提示音</div>
              </div>
            </label>
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notify-approvals" ${settings.notifyApprovals !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;">审批提醒</span>
                <div style="font-size: 12px; color: var(--text-secondary);">当工作流或会话请求写操作审批时通知</div>
              </div>
            </label>
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notify-completed" ${settings.notifyCompleted !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;">完成提醒</span>
                <div style="font-size: 12px; color: var(--text-secondary);">当任务成功结束或日志记录完成事件时通知</div>
              </div>
            </label>
            <label class="form-checkbox-label">
              <input type="checkbox" id="setting-notify-errors" ${settings.notifyErrors !== false ? 'checked' : ''}>
              <div>
                <span style="font-size: 13px;">错误与异常提醒</span>
                <div style="font-size: 12px; color: var(--text-secondary);">当任务失败、超时或日志记录异常中断时通知</div>
              </div>
            </label>
          </fieldset>

          <div class="sound-preview-bar" style="padding-top: 12px; border-top: 1px solid var(--border-color); display: flex; align-items: center; justify-content: space-between; gap: 10px; flex-wrap: wrap;">
            <div>
              <strong style="font-size: 13px;">提示音试听</strong>
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;">原生音效就绪，仅在用户点击时触发试听，不修改通知设置或请求系统权限。</div>
            </div>
            <div style="display: flex; align-items: center; gap: 8px;">
              <select id="setting-preview-sound-kind" class="filter-select" aria-label="试听音效事件类型">
                <option value="approval">待办审批提示音</option>
                <option value="completed">任务完成提示音</option>
                <option value="error">错误异常提示音</option>
              </select>
              <button id="btn-preview-notification-sound" class="btn btn-secondary btn-sm">试听提示音</button>
            </div>
          </div>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title">后台运行与启动</span>
        </div>
        <div style="display: flex; flex-direction: column; gap: 14px;">
          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-launch-at-login" ${settings.launchAtLogin ? 'checked' : ''}>
            <div>
              <strong style="font-size: 13px;">开机启动</strong>
              ${(state.systemInfo && (state.systemInfo.launchAtLoginStatus === 'pending_approval' || state.systemInfo.launchAtLoginStatus === 'requiresApproval')) ? '<span class="status-badge status-amber" style="margin-left: 6px;">待系统审批</span>' : ''}
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;">登录系统时自动在后台启动 Vela 状态栏驻留。</div>
            </div>
          </label>

          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-analysis" ${settings.analysisEnabled ? 'checked' : ''}>
            <div>
              <strong style="font-size: 13px;">后台分析</strong>
              <div style="font-size: 12px; color: var(--text-secondary); margin-top: 2px;">在后台定期检查新增会话，生成调优建议。</div>
            </div>
          </label>
        </div>

        <div style="margin-top: 16px; padding-top: 14px; border-top: 1px solid var(--border-color); display: flex; justify-content: flex-end;">
          <button id="btn-save-settings" class="btn btn-primary btn-sm">保存设置</button>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title">本地与隐私声明</span>
          <span class="status-badge status-sage">无遥测</span>
        </div>
        <ul style="padding-left: 18px; font-size: 12px; line-height: 1.6; color: var(--text-secondary);">
          <li><strong>当前存储路径：</strong><code class="code-badge">${escapeHtml(state.systemInfo.home)}</code> (Channel: ${escapeHtml(state.systemInfo.channel)})</li>
          <li><strong>无云端账户：</strong>Vela 不需要登录注册，无需联网认证。</li>
          <li><strong>本地优先存储：</strong>所有工程数据默认本地留存；用户授权的智能体根据其自身配置联网，Vela 不上传遥测或云端数据。</li>
          <li><strong>完全禁用遥测：</strong>无用户行为追踪、无崩溃日志上报。</li>
          <li><strong>私密隔离保护：</strong>标记为私密的 Library 条目严格对 MCP 和自动检索隐藏。</li>
        </ul>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title">外部智能体集成状态</span>
        </div>
        <div style="font-size: 12px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
          <div>Claude Desktop: <span class="status-badge status-neutral">支持 stdio MCP</span></div>
          <div>Cursor: <span class="status-badge status-neutral">支持 stdio MCP</span></div>
          <div>Codex: <span class="status-badge status-neutral">支持 Checkpoint 导出</span></div>
          <div>自动云端同步: <span class="status-badge status-neutral">不支持（本地优先，不上传云端）</span></div>
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
        showToast('无效的音效类型', 'error');
        return;
      }
      const btn = document.getElementById('btn-preview-notification-sound');
      if (btn) btn.disabled = true;
      try {
        await callBridge('system.previewNotificationSound', { kind });
        showToast(`已播放「${kind === 'approval' ? '审批' : kind === 'completed' ? '完成' : '错误'}」提示音试听`);
      } catch (err) {
        showToast('试听提示音失败: ' + (err.message || '原生接口未就绪或当前环境不支持音频播放'), 'error');
      } finally {
        if (btn) btn.disabled = false;
      }
    });
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
        showToast('设置已保存');
        await refreshDashboard(true, true);
      } catch (err) {
        showToast('保存设置失败: ' + err.message, 'error');
      }
    });
  }

  // -------------------------------------------------------------------------
  // GLOBAL MODALS (Cmd-K Search, Checkpoints)
  // -------------------------------------------------------------------------
  function openSearchModal() {
    const modalBody = `
      <div class="form-group">
        <input type="search" id="global-search-input" class="form-input" placeholder="输入搜索关键词（按 Enter 搜索）..." autofocus>
      </div>
      <div style="display: flex; align-items: center; justify-content: space-between; font-size: 11px;">
        <label class="form-checkbox-label">
          <input type="checkbox" id="search-include-private">
          <span>包含私密条目 (人工搜索可见)</span>
        </label>
        <span class="text-secondary">按 Esc 关闭</span>
      </div>
      <div id="search-results-list" style="margin-top: 10px; max-height: 280px; overflow-y: auto;">
        <div class="text-secondary" style="font-size: 11px; padding: 12px 0; text-align: center;">输入关键词以检索本地证据</div>
      </div>
    `;

    openModal('搜索工程上下文', modalBody, '');

    const input = document.getElementById('global-search-input');
    const chkPrivate = document.getElementById('search-include-private');
    const resultsList = document.getElementById('search-results-list');

    const doSearch = async () => {
      const query = input.value.trim();
      if (!query) return;
      resultsList.innerHTML = '<div class="text-secondary" style="font-size: 11px; padding: 10px 0;">搜索中...</div>';

      try {
        const results = await callBridge('search', {
          query,
          project: state.currentProject || undefined,
          includePrivate: chkPrivate.checked
        });

        const items = Array.isArray(results) ? results : [];
        if (items.length === 0) {
          resultsList.innerHTML = '<div style="font-size: 11px; color: var(--text-muted); padding: 16px 0; text-align: center;">未找到匹配证据</div>';
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
            openDrawer(item.title || item.id, item.kind ? `类别: ${item.kind}` : '本地证据详情');
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
                      ${escapeHtml(item.content || item.description || '(无详细文本)')}
                    </div>
                  </div>
                  ${item.project ? `
                    <div class="card" style="font-size: 12px;">
                      <div class="text-secondary" style="margin-bottom: 4px;">所属工程路径:</div>
                      <code class="code-badge">${escapeHtml(item.project)}</code>
                    </div>
                  ` : ''}
                  ${item.sourceFile ? `
                    <div class="card" style="font-size: 12px;">
                      <div class="text-secondary" style="margin-bottom: 4px;">来源文件:</div>
                      <code class="code-badge">${escapeHtml(item.sourceFile)}</code>
                    </div>
                  ` : ''}
                  ${item.metadata ? `
                    <div class="card">
                      <div class="card-header"><span class="card-title">元数据</span></div>
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

    setTimeout(() => input.focus(), 50);
  }

  function openSaveCheckpointModal(session) {
    const modalBody = `
      <div class="form-group">
        <label class="form-label">Checkpoint 标题</label>
        <input type="text" id="cp-title" class="form-input" value="${escapeHtml(session.title ? session.title + ' - 阶段总结' : '任务进展快照')}" placeholder="输入 Checkpoint 标题">
      </div>
      <div class="form-group">
        <label class="form-label">核心目标 (Goal)</label>
        <input type="text" id="cp-goal" class="form-input" placeholder="本次会话或任务的核心目标">
      </div>
      <div class="form-group">
        <label class="form-label">已完成工作 (Completed)</label>
        <textarea id="cp-completed" class="form-textarea" placeholder="已实现的功能、已修复的问题"></textarea>
      </div>
      <div class="form-group">
        <label class="form-label">待处理事项 (Pending)</label>
        <textarea id="cp-pending" class="form-textarea" placeholder="遗留缺陷或未完成的子任务"></textarea>
      </div>
      <div class="form-group">
        <label class="form-label">测试与验证情况 (Tests)</label>
        <input type="text" id="cp-tests" class="form-input" placeholder="运行过的测试与验证结果">
      </div>
      <div class="form-group">
        <label class="form-label">后续行动建议 (Next Actions)</label>
        <input type="text" id="cp-next" class="form-input" placeholder="下一个会话应当优先进行的操作">
      </div>
    `;

    openModal('保存跨智能体 Checkpoint', modalBody, `
      <button class="btn btn-secondary" id="btn-cancel-cp">取消</button>
      <button class="btn btn-primary" id="btn-save-cp">保存 Checkpoint</button>
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
        showToast('目标 (Goal) 字段不能为空', 'error');
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

        showToast('Checkpoint 保存成功');
        closeModal();

        if (cp && cp.id) {
          openExportCheckpointModal(cp.id);
        }
      } catch (err) {
        showToast('保存 Checkpoint 失败: ' + err.message, 'error');
      }
    });
  }

  async function openExportCheckpointModal(checkpointId) {
    let currentProvider = 'Claude';

    const renderExportBody = async () => {
      const exp = await callBridge('checkpoint.export', { id: checkpointId, provider: currentProvider });
      return `
        <div class="form-group">
          <label class="form-label">目标 Provider</label>
          <select id="cp-exp-prov" class="form-select">
            <option value="Claude" ${currentProvider === 'Claude' ? 'selected' : ''}>Claude</option>
            <option value="Codex" ${currentProvider === 'Codex' ? 'selected' : ''}>Codex</option>
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">生成的交接规约文件路径</label>
          <input type="text" class="form-input font-mono" readonly value="${escapeHtml(exp ? exp.path || '' : '')}">
        </div>
        <div class="form-group">
          <label class="form-label">
            <span>启动命令 (仅供复制，不自动启动外部工具)</span>
            <button class="btn btn-ghost btn-sm" id="btn-copy-cp-cmd">复制命令</button>
          </label>
          <input type="text" id="cp-exp-cmd" class="form-input font-mono" readonly value="${escapeHtml(exp ? exp.command || '' : '')}">
        </div>
        <div class="form-group">
          <label class="form-label">交接文件内容预览</label>
          <div class="code-view" style="max-height: 140px;">${escapeHtml(exp ? exp.content || '' : '')}</div>
        </div>
      `;
    };

    openModal('导出 Checkpoint 交接', await renderExportBody(), `
      <button class="btn btn-primary" id="btn-close-cp-exp">完成</button>
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
            showToast('已复制启动命令');
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

    if (e.shiftKey) {
      if (document.activeElement === first || !container.contains(document.activeElement)) {
        e.preventDefault();
        last.focus();
      }
    } else {
      if (document.activeElement === last || !container.contains(document.activeElement)) {
        e.preventDefault();
        first.focus();
      }
    }
  }

  function openDrawer(title, subtitle = '', triggerEl = null) {
    drawerTriggerElement = triggerEl || document.activeElement;
    const drawer = document.getElementById('detail-drawer');
    const backdrop = document.getElementById('drawer-backdrop');
    setDrawerTitle(title, subtitle);
    setDrawerCustomActions('');

    const isWide = window.innerWidth >= 1150;
    document.body.classList.toggle('has-inspector-open', isWide);

    if (drawer) drawer.classList.remove('hidden');
    if (backdrop) {
      if (isWide) {
        backdrop.classList.add('hidden');
      } else {
        backdrop.classList.remove('hidden');
      }
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
      if (drawer && !drawer.classList.contains('hidden')) {
        const closeBtn = document.getElementById('btn-close-drawer');
        const firstFocusable = drawer.querySelector('button:not([disabled]):not(#btn-close-drawer), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex="0"]');
        if (firstFocusable) {
          firstFocusable.focus();
        } else if (closeBtn) {
          closeBtn.focus();
        }
      }
    }, 20);
  }

  function setDrawerTitle(title, subtitle = '') {
    const t = document.getElementById('drawer-title');
    const s = document.getElementById('drawer-subtitle');
    if (t) t.textContent = title;
    if (s) s.textContent = subtitle;
  }

  function setDrawerCustomActions(html) {
    const act = document.getElementById('drawer-custom-actions');
    if (act) act.innerHTML = html;
  }

  function closeDrawer() {
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
    modalTriggerElement = triggerEl || document.activeElement;
    const modal = document.getElementById('modal-container');
    const dialog = document.getElementById('modal-dialog');
    const t = document.getElementById('modal-title');
    const b = document.getElementById('modal-body');
    const f = document.getElementById('modal-footer');
    if (t) t.textContent = title;
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
      if (modal && !modal.classList.contains('hidden')) {
        const firstInput = modal.querySelector('input:not([disabled]), textarea:not([disabled]), select:not([disabled]), button:not([disabled]):not(#btn-close-modal)');
        if (firstInput) {
          firstInput.focus();
        } else {
          const closeBtn = document.getElementById('btn-close-modal');
          if (closeBtn) closeBtn.focus();
        }
      }
    }, 20);
  }

  function closeModal() {
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
