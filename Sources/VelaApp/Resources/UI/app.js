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
    dashboard: null,
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
    // Settings draft and snapshot cache
    settingsDraft: null,
    lastSnapshotJson: null
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
    setupShortcuts();
    setupEventListeners();

    if (window.vela && typeof window.vela.call === 'function') {
      state.isBridgeAvailable = true;
      try {
        await callBridge('system.ready');
      } catch (err) {
        console.warn('system.ready returned error:', err);
      }
      try {
        const info = await callBridge('system.info');
        if (info) {
          state.systemInfo = info;
          updateSystemInfoDisplay();
        }
      } catch {}
    } else {
      // Browser preview mode ONLY
      state.isDemoMode = true;
      const banner = document.getElementById('demo-banner');
      if (banner) banner.classList.remove('hidden');
      await loadDemoScript();
    }

    await refreshDashboard(true, true);
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

  let isRefreshing = false;
  let hasQueuedRefresh = false;
  let queuedForceRedraw = false;
  let queuedShowErrorBanner = false;

  // Dashboard Sync with Safe Polling (Doesn't destroy forms or settings drafts)
  async function refreshDashboard(showErrorBanner = true, forceRedraw = false) {
    if (isRefreshing) {
      hasQueuedRefresh = true;
      if (forceRedraw) queuedForceRedraw = true;
      if (showErrorBanner) queuedShowErrorBanner = true;
      return;
    }
    isRefreshing = true;
    try {
      const result = await callBridge('dashboard.get', state.currentProject ? { project: state.currentProject } : {});
      if (result) {
        state.dashboard = result;
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

        // Compare real change-bearing data: serialize actual result data, current page, and project
        const snapshotKey = JSON.stringify({
          page: state.currentPage,
          project: state.currentProject,
          data: result
        });
        const isIdentical = state.lastSnapshotJson === snapshotKey;
        state.lastSnapshotJson = snapshotKey;

        if (forceRedraw || (!isEditing && !isModalOpen && !isDrawerOpen && !hasSettingsDraft && !isIdentical)) {
          renderCurrentPage();
        }
        hideGlobalError();
      }
    } catch (err) {
      if (showErrorBanner) {
        showGlobalError('获取本地数据失败：' + (err.message || '未知错误'));
      }
      // If initial load failed and no dashboard data exists, show clear retry view
      if (!state.dashboard) {
        const container = document.getElementById('page-container');
        if (container) {
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
      }
    } finally {
      isRefreshing = false;
      if (hasQueuedRefresh) {
        hasQueuedRefresh = false;
        const nextForce = queuedForceRedraw;
        const nextShowError = queuedShowErrorBanner;
        queuedForceRedraw = false;
        queuedShowErrorBanner = false;
        setTimeout(() => {
          refreshDashboard(nextShowError, nextForce);
        }, 0);
      }
    }
  }

  function updateGlobalCounters() {
    if (!state.dashboard) return;
    const approvals = state.dashboard.approvals || [];
    // Only pending approvals count towards badge
    const pendingCount = approvals.filter(a => {
      const st = (a.state || '').toLowerCase();
      return st === 'pending' || st === 'pending approval' || st === '';
    }).length;

    const badge = document.getElementById('badge-inbox-count');
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
    sel.innerHTML = '<option value="">所有项目 (All Projects)</option>';
    for (const proj of state.registeredProjects) {
      const opt = document.createElement('option');
      opt.value = proj.path || proj.id || '';
      opt.textContent = proj.title || proj.name || proj.path || '未命名项目';
      if (opt.value === curr) opt.selected = true;
      sel.appendChild(opt);
    }
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
        closeDrawer();
        closeModal();
        return;
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

    window.addEventListener('vela:refresh', () => {
      refreshDashboard(true, true);
      showToast('数据已刷新');
    });

    window.addEventListener('vela:search', () => {
      openSearchModal();
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
        state.currentProject = e.target.value;
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
  }

  function navigateTo(page) {
    state.currentPage = page;
    state.settingsDraft = null;
    document.querySelectorAll('.nav-link').forEach(link => {
      if (link.getAttribute('data-page') === page) {
        link.classList.add('active');
        link.setAttribute('aria-current', 'page');
      } else {
        link.classList.remove('active');
        link.removeAttribute('aria-current');
      }
    });
    renderCurrentPage();
  }

  // =========================================================================
  // VIEW RENDERERS
  // =========================================================================

  function renderCurrentPage() {
    const container = document.getElementById('page-container');
    if (!container) return;

    switch (state.currentPage) {
      case 'agents': renderAgentsView(container); break;
      case 'workflows': renderWorkflowsView(container); break;
      case 'setup': renderSetupView(container); break;
      case 'usage': renderUsageView(container); break;
      case 'improve': renderImproveView(container); break;
      case 'lab': renderLabView(container); break;
      case 'inbox': renderInboxView(container); break;
      case 'settings': renderSettingsView(container); break;
      default: renderAgentsView(container);
    }
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

    const runningCount = filteredSessions.filter(s => s.state === 'Running').length;

    const hasCopilot = filteredSessions.some(s => (s.provider || '').toLowerCase() === 'copilot');

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>Agents 会话</h1>
          <p>观察多智能体会话日志、工具调用与上下文证据 · 共 ${filteredSessions.length} 个会话 (${runningCount} 运行中)</p>
        </div>
        <div class="page-actions">
          <button id="btn-refresh-sessions" class="btn btn-secondary btn-sm">增量刷新</button>
          <button id="btn-add-project-agents" class="btn btn-primary btn-sm">+ 连接项目</button>
        </div>
      </div>

      <div class="toolbar-bar">
        <div class="toolbar-filters">
          <input type="search" id="session-search-input" class="filter-input" placeholder="搜索会话标题、模型或路径..." style="width: 240px;" value="${escapeHtml(state.sessionFilterQuery)}">
          <select id="session-provider-filter" class="filter-select">
            <option value="">所有 Provider</option>
            <option value="claude" ${(state.sessionProviderFilter || '').toLowerCase() === 'claude' ? 'selected' : ''}>claude</option>
            <option value="codex" ${(state.sessionProviderFilter || '').toLowerCase() === 'codex' ? 'selected' : ''}>codex</option>
            <option value="cursor" ${(state.sessionProviderFilter || '').toLowerCase() === 'cursor' ? 'selected' : ''}>cursor</option>
            ${hasCopilot ? `<option value="copilot" ${(state.sessionProviderFilter || '').toLowerCase() === 'copilot' ? 'selected' : ''}>copilot</option>` : ''}
          </select>
          <select id="session-status-filter" class="filter-select">
            <option value="">所有状态</option>
            <option value="running" ${(state.sessionStatusFilter || '').toLowerCase() === 'running' ? 'selected' : ''}>Running (运行中)</option>
            <option value="idle" ${(state.sessionStatusFilter || '').toLowerCase() === 'idle' ? 'selected' : ''}>Idle (空闲)</option>
            <option value="completed" ${(state.sessionStatusFilter || '').toLowerCase() === 'completed' ? 'selected' : ''}>Completed (已完成)</option>
            <option value="needs approval" ${(state.sessionStatusFilter || '').toLowerCase() === 'needs approval' ? 'selected' : ''}>Needs Approval (待审批)</option>
            <option value="error" ${(state.sessionStatusFilter || '').toLowerCase() === 'error' ? 'selected' : ''}>Error (错误)</option>
            <option value="stopped" ${(state.sessionStatusFilter || '').toLowerCase() === 'stopped' ? 'selected' : ''}>Stopped (已停止)</option>
            <option value="unknown" ${(state.sessionStatusFilter || '').toLowerCase() === 'unknown' ? 'selected' : ''}>未知（仅日志）</option>
          </select>
        </div>
        <span class="text-secondary" style="font-size: 11px;">点击行打开详情与 Checkpoint</span>
      </div>

      <div class="table-wrapper">
        <table class="data-table" id="sessions-table">
          <thead>
            <tr>
              <th style="width: 100px;">Provider</th>
              <th>标题 / 任务</th>
              <th>项目 / 分支</th>
              <th style="width: 130px;">模型</th>
              <th style="width: 120px;">状态</th>
              <th style="width: 110px;">Token (I/O)</th>
              <th style="width: 120px;">最后更新</th>
            </tr>
          </thead>
          <tbody id="sessions-table-body"></tbody>
        </table>
      </div>

      <div id="sessions-empty-state" class="empty-state ${filteredSessions.length === 0 ? '' : 'hidden'}">
        <div class="empty-state-title">未检测到会话日志</div>
        <div class="empty-state-desc">Vela 会自动监听已连接项目的编码智能体日志目录（如 Claude Desktop、Cursor、Codex）。连接本地项目后，会话日志将在此自动更新。</div>
        <button id="btn-empty-add-proj" class="btn btn-primary btn-sm">+ 添加项目</button>
      </div>
    `;

    applySessionFilters(filteredSessions);

    const searchInput = document.getElementById('session-search-input');
    const provFilter = document.getElementById('session-provider-filter');
    const statusFilter = document.getElementById('session-status-filter');

    const filterHandler = () => {
      state.sessionFilterQuery = (searchInput.value || '').trim();
      state.sessionProviderFilter = (provFilter.value || '').trim().toLowerCase();
      state.sessionStatusFilter = (statusFilter.value || '').trim().toLowerCase();
      applySessionFilters(filteredSessions);
    };

    searchInput.addEventListener('input', filterHandler);
    provFilter.addEventListener('change', filterHandler);
    statusFilter.addEventListener('change', filterHandler);

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

    const emptyBtn = document.getElementById('btn-empty-add-proj');
    if (emptyBtn) emptyBtn.addEventListener('click', () => document.getElementById('btn-add-project').click());
  }

  function applySessionFilters(filteredSessions) {
    const q = (state.sessionFilterQuery || '').toLowerCase();
    const prov = (state.sessionProviderFilter || '').trim().toLowerCase();
    const st = (state.sessionStatusFilter || '').trim().toLowerCase();

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

    renderSessionRows(res);
  }

  function renderSessionRows(sessionsList) {
    const tbody = document.getElementById('sessions-table-body');
    const emptyState = document.getElementById('sessions-empty-state');
    if (!tbody) return;

    if (sessionsList.length === 0) {
      tbody.innerHTML = '';
      if (emptyState) emptyState.classList.remove('hidden');
      return;
    }
    if (emptyState) emptyState.classList.add('hidden');

    tbody.innerHTML = sessionsList.map(s => {
      const stateBadge = getSessionStateBadge(s.state);
      const totalTokens = (s.tokenInput || 0) + (s.tokenOutput || 0);
      const tokensDisplay = totalTokens > 0 ? `${s.tokenInput || 0} / ${s.tokenOutput || 0}` : '-';
      const tooltipParts = [];
      if (s.statusSource) tooltipParts.push(`状态来源: ${s.statusSource}`);
      if (s.statusInferred) tooltipParts.push('状态由日志推断（非实时进程状态）');
      const cellTooltip = tooltipParts.join(' · ');
      return `
        <tr class="clickable-row ${state.selectedSessionId === s.id ? 'selected' : ''}" data-id="${escapeHtml(s.id)}">
          <td><span class="code-badge">${escapeHtml(s.provider || 'AI')}</span></td>
          <td style="font-weight: 500;">${escapeHtml(s.title || '未命名会话')}</td>
          <td>
            <div style="font-size: 11px; color: var(--text-secondary);">${escapeHtml(s.project ? s.project.split('/').pop() : '-')}</div>
            <div style="font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(s.branch || '-')}</div>
          </td>
          <td><span style="font-size: 11px; font-family: var(--font-mono);">${escapeHtml(s.model || '-')}</span></td>
          <td>
            <div ${cellTooltip ? `title="${escapeHtml(cellTooltip)}"` : ''} style="display: inline-flex; flex-direction: column; gap: 2px;">
              ${stateBadge}
              ${s.statusInferred ? `<span class="text-muted" style="font-size: 10px;" aria-label="状态由日志推断">状态由日志推断</span>` : ''}
            </div>
          </td>
          <td><span style="font-family: var(--font-mono); font-size: 11px;">${escapeHtml(tokensDisplay)}</span></td>
          <td style="font-size: 11px; color: var(--text-secondary);">${formatTime(s.updatedAt || s.lastActivity)}</td>
        </tr>
      `;
    }).join('');

    tbody.querySelectorAll('tr.clickable-row').forEach(row => {
      row.addEventListener('click', () => {
        const id = row.getAttribute('data-id');
        openSessionDetail(id);
      });
    });
  }

  function getSessionStateBadge(stateStr) {
    switch (stateStr) {
      case 'Running':
        return '<span class="status-badge status-amber">● 运行中</span>';
      case 'Completed':
        return '<span class="status-badge status-sage">✓ 已完成</span>';
      case 'Needs Approval':
        return '<span class="status-badge status-amber">待审批</span>';
      case 'Error':
        return '<span class="status-badge status-red">错误</span>';
      case 'Stopped':
        return '<span class="status-badge status-neutral">已停止</span>';
      case 'Idle':
        return '<span class="status-badge status-neutral">空闲</span>';
      default:
        return '<span class="status-badge status-neutral">未知（仅日志）</span>';
    }
  }

  async function openSessionDetail(sessionId) {
    state.selectedSessionId = sessionId;
    openDrawer('正在加载会话详情...', sessionId);

    try {
      const session = await callBridge('sessions.get', { id: sessionId });
      if (!session) throw new Error('会话不存在');

      setDrawerTitle(session.title || '会话详情', sessionId);
      setDrawerCustomActions(`
        <button id="btn-save-checkpoint-modal" class="btn btn-secondary btn-sm">保存 Checkpoint</button>
      `);

      document.getElementById('btn-save-checkpoint-modal').addEventListener('click', () => {
        openSaveCheckpointModal(session);
      });

      const drawerBody = document.getElementById('drawer-content');
      const messages = session.messages || [];

      drawerBody.innerHTML = `
        <div class="card">
          <div class="card-header">
            <span class="card-title">元数据</span>
            <div style="display: flex; align-items: center; gap: 6px;">
              ${session.statusInferred ? '<span class="status-badge status-neutral" style="font-size: 10px;" aria-label="状态由日志推断">状态由日志推断</span>' : ''}
              ${getSessionStateBadge(session.state)}
            </div>
          </div>
          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; font-size: 11px;">
            <div><span class="text-secondary">Provider:</span> <strong>${escapeHtml(session.provider)}</strong></div>
            <div><span class="text-secondary">Model:</span> <span class="font-mono">${escapeHtml(session.model || '-')}</span></div>
            <div><span class="text-secondary">Project:</span> <span class="font-mono">${escapeHtml(session.project || '-')}</span></div>
            <div><span class="text-secondary">Branch:</span> <span class="font-mono">${escapeHtml(session.branch || '-')}</span></div>
            <div><span class="text-secondary">Tokens:</span> <span class="font-mono">${(session.tokenInput || 0) + (session.tokenOutput || 0)}</span></div>
            <div><span class="text-secondary">时间:</span> ${formatTime(session.updatedAt)}</div>
            ${session.statusSource ? `<div><span class="text-secondary">状态来源:</span> <span class="font-mono">${escapeHtml(session.statusSource)}</span></div>` : ''}
            ${session.statusInferred ? `<div><span class="text-secondary">状态判定:</span> <span style="color: var(--status-amber-text, #f59e0b);" aria-label="状态由日志推断">状态由日志推断</span></div>` : ''}
          </div>
          ${session.sourcePath ? `<div style="margin-top: 8px; font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">日志: ${escapeHtml(session.sourcePath)}</div>` : ''}
        </div>

        <div>
          <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px;">
            <h3 style="font-size: 13px; font-weight: 600;">消息流 (${messages.length})</h3>
            <span style="font-size: 11px; color: var(--text-secondary);">单条消息可存为候选 Memory</span>
          </div>

          <div style="display: flex; flex-direction: column; gap: 10px;">
            ${messages.length === 0 ? '<div class="text-secondary" style="font-size: 12px; padding: 12px 0;">无详细消息记录（仅捕获会话级统计）</div>' : ''}
            ${messages.map((m, idx) => `
              <div class="card" style="margin-bottom: 0; padding: 10px 12px;">
                <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 6px;">
                  <div style="display: flex; align-items: center; gap: 6px;">
                    <span class="status-badge status-neutral" style="font-size: 10px;">${escapeHtml(m.role || 'message')}</span>
                    <span style="font-size: 10px; color: var(--text-muted);">${formatTime(m.timestamp)}</span>
                  </div>
                  <button class="btn btn-ghost btn-sm btn-save-msg-memory" data-idx="${idx}" title="保存此消息为 Memory">
                    + 存为 Memory
                  </button>
                </div>
                <div class="code-view" style="font-size: 11px; max-height: 180px;">${escapeHtml(m.content || '')}</div>
                ${m.tool ? `<div style="margin-top: 6px; font-size: 10px; font-family: var(--font-mono); color: var(--text-secondary);">工具调用: <strong>${escapeHtml(m.tool)}</strong></div>` : ''}
              </div>
            `).join('')}
          </div>
        </div>
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

    } catch (err) {
      setDrawerTitle('加载失败', sessionId);
      document.getElementById('drawer-content').innerHTML = `
        <div class="alert-banner alert-danger">
          无法获取会话详情：${escapeHtml(err.message)}
        </div>
      `;
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
          <h1>Workflows 工作流</h1>
          <p>确定性多步骤自动化编排 · 安全工具门禁 · 运行记录与试运行</p>
        </div>
        <div class="page-actions">
          <button id="btn-build-wf-prompt" class="btn btn-secondary btn-sm">描述工作流 (Draft)</button>
          <button id="btn-new-workflow" class="btn btn-primary btn-sm">+ 新建工作流</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.workflowsActiveTab === 'list' ? 'active' : ''}" data-wftab="list">工作流列表 (${workflows.length})</button>
        <button class="tab-btn ${state.workflowsActiveTab === 'runs' ? 'active' : ''}" data-wftab="runs">运行记录 (Run Ledger) (${runs.length})</button>
        <button class="tab-btn ${state.workflowsActiveTab === 'health' ? 'active' : ''}" data-wftab="health">健康度 (Health)</button>
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
                    <div style="font-size: 11px; color: var(--text-secondary);">${escapeHtml(wf.description || '-')}</div>
                  </td>
                  <td>
                    <span class="code-badge">${escapeHtml(wf.trigger || 'manual')}</span>
                    ${wf.cron ? `<span style="font-size: 10px; font-family: var(--font-mono); color: var(--text-muted); margin-left: 4px;">${escapeHtml(wf.cron)}</span>` : ''}
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
    openDrawer('正在加载运行审计记录...', runId);

    try {
      const run = await callBridge('runs.get', { id: runId });
      if (!run) throw new Error('未找到该运行记录');

      setDrawerTitle(run.title || '运行详情', run.id);
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
                    ${step.durationMs ? `<span style="font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(String(step.durationMs))}ms</span>` : ''}
                    ${getRunStateBadge(step.state)}
                  </div>
                </div>
                ${step.output ? `
                  <div class="code-view" style="max-height: 160px; font-size: 11px;">${escapeHtml(typeof step.output === 'string' ? step.output : JSON.stringify(step.output, null, 2))}</div>
                ` : '<div style="font-size: 11px; color: var(--text-muted);">（无输出）</div>'}
              </div>
            `).join('')}
          </div>
        </div>
      `;
    } catch (err) {
      setDrawerTitle('加载失败', runId);
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
            <textarea class="form-textarea code-editor wf-step-args" data-idx="${idx}" style="min-height: 48px; font-size: 10px; padding: 4px 6px;" placeholder="${s.tool === 'agent.run' ? '请输入已安装的 CLI 可执行文件 (executable) 与参数 (args)...' : '参数 JSON'}">${escapeHtml(typeof s.arguments === 'object' ? JSON.stringify(s.arguments, null, 2) : s.arguments || '{}')}</textarea>
            ${s.tool === 'agent.run' ? '<div style="font-size: 10px; color: var(--text-secondary); margin-top: 2px;">提示：须填写真实已安装的 CLI 可执行文件 (executable) 与参数数组 (args)。</div>' : ''}
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
          <h1>Setup 项目配置与资产</h1>
          <p>工程规则、MCP 协议、环境规约、持久 Memory 与本地知识库</p>
        </div>
        <div class="page-actions">
          <button id="btn-scan-setup" class="btn btn-secondary btn-sm">扫描配置 (Scan)</button>
          <button id="btn-audit-setup" class="btn btn-secondary btn-sm">配置审计 (Audit)</button>
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
    const filtered = artifacts.filter(a => (a.type || '').toLowerCase() === typeName.toLowerCase());

    target.innerHTML = `
      <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px;">
        <span class="text-secondary" style="font-size: 12px;">共 ${filtered.length} 项 ${escapeHtml(typeName)} 资产 · 本地只读预览与定位</span>
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
                    <div style="font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">${escapeHtml(a.path || '')}</div>
                  </td>
                  <td>
                    <span class="code-badge">${escapeHtml(a.provider || 'generic')}</span>
                    <span style="font-size: 11px; color: var(--text-secondary); margin-left: 4px;">${escapeHtml(a.scope || 'project')}</span>
                  </td>
                  <td><span class="font-mono">${escapeHtml(String(a.tokens || '-'))}</span></td>
                  <td><span class="font-mono" style="font-size: 10px;">${a.hash ? escapeHtml(a.hash.substring(0, 10)) : '-'}</span></td>
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
              <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 6px;">
                <div><span class="text-secondary">类型:</span> ${escapeHtml(art.type)}</div>
                <div><span class="text-secondary">Provider:</span> ${escapeHtml(art.provider)}</div>
                <div><span class="text-secondary">Token 估算:</span> ${escapeHtml(String(art.tokens || '-'))}</div>
                <div><span class="text-secondary">Hash:</span> <span class="font-mono">${escapeHtml(art.hash || '-')}</span></div>
              </div>
              <div style="margin-top: 8px; font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">路径: ${escapeHtml(art.path || '-')}</div>
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
      const list = Array.isArray(guidelines) ? guidelines : [];
      const cont = document.getElementById('guidelines-list-container');
      if (!cont) return;

      if (list.length === 0) {
        cont.innerHTML = `
          <div class="empty-state">
            <div class="empty-state-title">未配置 Guidelines 指南</div>
            <div class="empty-state-desc">为项目建立编码与架构指南。记录静态源快照（mode: snapshot_only_not_injected），未注入智能体执行上下文。</div>
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
                  <div><span class="text-secondary">生效模式:</span> <span class="font-mono">snapshot_only_not_injected</span></div>
                  <div><span class="text-secondary">运行时影响:</span> 静态快照 · 未注入智能体执行上下文</div>
                </div>
              </div>
              <div>
                <h3 style="font-size: 13px; font-weight: 600; margin-bottom: 6px;">源快照内容 (Source Snapshot)</h3>
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
      document.getElementById('guidelines-list-container').innerHTML = `
        <div class="alert-banner alert-danger">加载 Guidelines 失败: ${escapeHtml(err.message)}</div>
      `;
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
            <option value="project" ${(initial && initial.scope === 'project') ? 'selected' : ''}>project (指定项目)</option>
            <option value="global" ${(initial && initial.scope === 'global') ? 'selected' : ''}>global (全局通用)</option>
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
                  <td><span style="font-size: 11px; color: var(--text-secondary);">${escapeHtml(m.type || 'fact')}</span></td>
                  <td>${getMemoryStateBadge(st)}</td>
                  <td style="font-size: 10px; font-family: var(--font-mono); color: var(--text-muted);">${provenance}</td>
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
        return '<span class="status-badge status-sage">Active (生效中)</span>';
      case 'candidate':
        return '<span class="status-badge status-amber">Candidate (待审)</span>';
      case 'superseded':
        return '<span class="status-badge status-neutral">Superseded (已替代)</span>';
      case 'archived':
        return '<span class="status-badge status-neutral">Archived (已归档)</span>';
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
          <label class="form-label">类型 (Type)</label>
          <select id="mem-type" class="form-select">
            ${validTypes.map(t => `<option value="${t}" ${((initial.type || 'fact').toLowerCase() === t) ? 'selected' : ''}>${t}</option>`).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">作用域 (Scope)</label>
          <select id="mem-scope" class="form-select">
            ${validScopes.map(s => `<option value="${s}" ${((initial.scope || 'project').toLowerCase() === s) ? 'selected' : ''}>${s}</option>`).join('')}
          </select>
        </div>
      </div>
      <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
        <div class="form-group">
          <label class="form-label">项目 (Project)</label>
          <select id="mem-project" class="form-select">
            <option value="">(全局 Global)</option>
            ${state.registeredProjects.map(p => `
              <option value="${escapeHtml(p.path || p.id)}" ${(initial.project === (p.path || p.id)) ? 'selected' : ''}>${escapeHtml(p.title || p.path)}</option>
            `).join('')}
          </select>
        </div>
        <div class="form-group">
          <label class="form-label">状态 (State)</label>
          <select id="mem-state" class="form-select" ${isEdit ? 'disabled' : ''}>
            <option value="candidate" ${(initial.state || 'candidate').toLowerCase() === 'candidate' ? 'selected' : ''}>candidate (候选)</option>
            <option value="active" ${(initial.state || '').toLowerCase() === 'active' ? 'selected' : ''}>active (生效中)</option>
            <option value="superseded" ${(initial.state || '').toLowerCase() === 'superseded' ? 'selected' : ''}>superseded (已替代)</option>
            <option value="archived" ${(initial.state || '').toLowerCase() === 'archived' ? 'selected' : ''}>archived (已归档)</option>
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
      <details style="margin-top: 8px; margin-bottom: 8px; font-size: 11px; color: var(--text-secondary);">
        <summary style="cursor: pointer; user-select: none; font-weight: 500;">高级上下文参数 (可选：Branch, Worktree, Task, SessionId)</summary>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 8px;">
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 10px;">Branch 分支</label>
            <input type="text" id="recall-branch" class="form-input" style="font-size: 11px;" placeholder="例如：main, feature/v2">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 10px;">Worktree 路径</label>
            <input type="text" id="recall-worktree" class="form-input" style="font-size: 11px;" placeholder="例如：/path/to/worktree">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 10px;">Task 任务标识</label>
            <input type="text" id="recall-task" class="form-input" style="font-size: 11px;" placeholder="例如：task-123">
          </div>
          <div class="form-group" style="margin-bottom: 0;">
            <label class="form-label" style="font-size: 10px;">Session ID 会话标识</label>
            <input type="text" id="recall-session-id" class="form-input" style="font-size: 11px;" placeholder="例如：sess-uuid">
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

  function renderMcpSection(target) {
    target.innerHTML = `
      <div class="card">
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
    `;
  }

  // -------------------------------------------------------------------------
  // 4. USAGE VIEW
  // -------------------------------------------------------------------------
  async function renderUsageView(container) {
    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>Usage 用量追踪</h1>
          <p>本地会话日志观察到的 Token 消耗与模型调用分布 · 100% 本地分析</p>
        </div>
      </div>

      <div class="alert-banner alert-info" style="margin-bottom: 14px;">
        <span>* 观察声明：本页面展示的 Token 统计源自本地会话日志观察值，仅供工程参考，非云端计费账单。</span>
      </div>

      <div class="stat-grid" id="usage-stat-grid">
        <div class="stat-card">
          <div class="stat-label">总观察 Token (Observed)</div>
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
                <th>云端额度状态 (Quota)</th>
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
      if (usage) {
        document.getElementById('usage-total-tokens').textContent = formatNumber(usage.totalTokens || 0);
        document.getElementById('usage-total-sessions').textContent = formatNumber(usage.sessionCount || 0);

        const providers = usage.providers || [];
        document.getElementById('usage-provider-count').textContent = providers.length;

        const tbody = document.getElementById('usage-provider-tbody');
        if (providers.length === 0) {
          tbody.innerHTML = '<tr><td colspan="6" style="text-align:center; color:var(--text-muted); padding:20px;">未发现本地日志 Token 数据</td></tr>';
        } else {
          tbody.innerHTML = providers.map(p => `
            <tr>
              <td><strong>${escapeHtml(p.provider)}</strong></td>
              <td class="font-mono">${formatNumber(p.inputTokens || 0)}</td>
              <td class="font-mono">${formatNumber(p.outputTokens || 0)}</td>
              <td class="font-mono"><strong>${formatNumber(p.totalTokens || 0)}</strong></td>
              <td>${formatNumber(p.sessionCount || 0)}</td>
              <td>
                <span class="status-badge status-neutral">${p.quotaAvailable ? escapeHtml(p.quota) : '额度未提供'}</span>
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
      document.getElementById('usage-stat-grid').innerHTML = `
        <div class="alert-banner alert-danger">无法加载用量数据：${escapeHtml(err.message)}</div>
      `;
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
          <h1>Improve 调优建议</h1>
          <p>从反复出现的会话模式中提炼确定性改进方案 · 严格证据阈值与原子回滚</p>
        </div>
        <div class="page-actions">
          <button id="btn-run-analysis" class="btn btn-primary btn-sm">分析工程证据 (Analyze)</button>
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
    openDrawer('加载 Diff 详情...', suggestionId);

    try {
      const previewObj = await callBridge('improve.preview', { id: suggestionId });
      if (!previewObj) throw new Error('未获取到预览数据');

      setDrawerTitle(previewObj.title || '建议详情', suggestionId);
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
      setDrawerTitle('加载失败', suggestionId);
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
          <h1>Lab 对照实验</h1>
          <p>确定性命令对照评测 (deterministic_command) · 独立 Git Worktree 运行 · 真实退出状态与耗时</p>
        </div>
        <div class="page-actions">
          <button id="btn-new-lab" class="btn btn-primary btn-sm">+ 新建对照实验</button>
        </div>
      </div>

      <div class="tabs-nav">
        <button class="tab-btn ${state.labActiveTab === 'evals' ? 'active' : ''}" data-labtab="evals">实验列表 (${evals.length})</button>
        <button class="tab-btn ${state.labActiveTab === 'regression' ? 'active' : ''}" data-labtab="regression">回归分析 (Regression)</button>
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
    target.innerHTML = `<div class="text-secondary" style="font-size: 12px; padding: 20px 0;">加载回归分析数据...</div>`;

    try {
      const reg = await callBridge('regression.list', state.currentProject ? { project: state.currentProject } : {});
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
    openDrawer('加载对照评测详情...', evalId);

    try {
      const cmp = await callBridge('lab.compare', { id: evalId });
      if (!cmp) throw new Error('未获取到评测对照数据');

      setDrawerTitle(cmp.title || '实验对照结果', evalId);
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
              <div style="font-size: 11px; margin-bottom: 6px;">
                平均耗时: <strong>${summary.baseline ? Math.round(summary.baseline.averageDurationMs || 0) + 'ms' : '-'}</strong>
              </div>
              <div style="display: flex; flex-direction: column; gap: 6px; max-height: 200px; overflow-y: auto;">
                ${baselineRuns.map((r, i) => `
                  <div style="background: var(--bg-subtle); padding: 6px; border-radius: 4px; font-size: 10px;">
                    <div><strong>第 ${i + 1} 次</strong> · Exit: ${escapeHtml(String(r.exitCode))} · ${r.durationMs || 0}ms ${r.timedOut ? '(超时)' : ''}</div>
                    <div class="code-view" style="font-size: 10px; margin-top: 4px; max-height: 80px;">${escapeHtml(r.output || '(无输出)')}</div>
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
              <div style="font-size: 11px; margin-bottom: 6px;">
                平均耗时: <strong>${summary.candidate ? Math.round(summary.candidate.averageDurationMs || 0) + 'ms' : '-'}</strong>
              </div>
              <div style="display: flex; flex-direction: column; gap: 6px; max-height: 200px; overflow-y: auto;">
                ${candidateRuns.map((r, i) => `
                  <div style="background: var(--bg-subtle); padding: 6px; border-radius: 4px; font-size: 10px;">
                    <div><strong>第 ${i + 1} 次</strong> · Exit: ${escapeHtml(String(r.exitCode))} · ${r.durationMs || 0}ms ${r.timedOut ? '(超时)' : ''}</div>
                    <div class="code-view" style="font-size: 10px; margin-top: 4px; max-height: 80px;">${escapeHtml(r.output || '(无输出)')}</div>
                  </div>
                `).join('')}
              </div>
            </div>
          </div>

          ${(summary.runtimeDeltaMs !== undefined || summary.successDelta !== undefined) ? `
            <div class="card" style="margin-top: 10px;">
              <div class="card-header"><span class="card-title">对照结论统计 (Summary Deltas)</span></div>
              <div style="font-size: 11px; display: grid; grid-template-columns: 1fr 1fr; gap: 8px;">
                <div>耗时差异: <strong>${summary.runtimeDeltaMs !== undefined ? escapeHtml(String(summary.runtimeDeltaMs)) + 'ms' : '-'}</strong></div>
                <div>成功率变化: <strong>${summary.successDelta !== undefined ? escapeHtml(String(summary.successDelta)) : '-'}</strong></div>
              </div>
            </div>
          ` : ''}
        `}
      `;
    } catch (err) {
      setDrawerTitle('加载失败', evalId);
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

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>Inbox 待执行操作与审批</h1>
          <p>所有写操作、脚本执行与对照实验的安全审查门禁 · 参数完全冻结，只运行审批快照</p>
        </div>
      </div>

      ${pendingApprovals.length === 0 ? `
        <div class="empty-state">
          <div class="empty-state-title">当前无待执行操作</div>
          <div class="empty-state-desc">当工作流包含测试/写入步骤，或创建 Lab 实验时，待办审批将在此出现。审批通过前命令不会被执行。</div>
        </div>
      ` : `
        <div style="display: flex; flex-direction: column; gap: 12px;">
          ${pendingApprovals.map(appr => `
            <div class="card" style="margin-bottom: 0;">
              <div class="card-header">
                <div>
                  <strong style="font-size: 14px;">${escapeHtml(appr.title || '操作执行申请')}</strong>
                  <span class="code-badge" style="margin-left: 6px;">${escapeHtml(appr.tool || 'command')}</span>
                </div>
                <span class="status-badge status-amber">待审批</span>
              </div>

              <div style="font-size: 11px; color: var(--text-secondary); margin-bottom: 8px;">
                项目: <span class="font-mono">${escapeHtml(appr.project || '-')}</span> ·
                快照哈希: <span class="font-mono" style="font-size: 10px;">${appr.snapshotHash ? escapeHtml(appr.snapshotHash.substring(0, 12)) : '-'}</span>
              </div>

              <div style="margin-bottom: 12px;">
                <div style="font-size: 11px; font-weight: 600; margin-bottom: 4px;">冻结参数 (Frozen Arguments)</div>
                <div class="code-view" style="font-size: 11px; max-height: 120px;">${escapeHtml(typeof appr.arguments === 'object' ? JSON.stringify(appr.arguments, null, 2) : appr.arguments || '{}')}</div>
              </div>

              <div style="display: flex; justify-content: flex-end; gap: 8px;">
                <button class="btn btn-secondary btn-sm btn-reject-appr" data-id="${escapeHtml(appr.id)}" data-hash="${escapeHtml(appr.snapshotHash || '')}">拒绝 (Reject)</button>
                <button class="btn btn-primary btn-sm btn-approve-appr" data-id="${escapeHtml(appr.id)}" data-hash="${escapeHtml(appr.snapshotHash || '')}">批准并执行 (Approve)</button>
              </div>
            </div>
          `).join('')}
        </div>
      `}
    `;

    container.querySelectorAll('.btn-approve-appr').forEach(btn => {
      btn.addEventListener('click', async () => {
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
        }
      });
    });

    container.querySelectorAll('.btn-reject-appr').forEach(btn => {
      btn.addEventListener('click', async () => {
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
        }
      });
    });
  }

  // -------------------------------------------------------------------------
  // 8. SETTINGS VIEW
  // -------------------------------------------------------------------------
  async function renderSettingsView(container) {
    let settings = state.rawSettings || {};
    try {
      const s = await callBridge('settings.get');
      if (s) settings = s;
    } catch {}

    // Merge in-progress user draft so background polls or label clicks don't revert inputs
    if (state.settingsDraft) {
      settings = Object.assign({}, settings, state.settingsDraft);
    }

    container.innerHTML = `
      <div class="page-header">
        <div class="page-title-group">
          <h1>Settings 设置</h1>
          <p>本地偏好设置 · 隐私声明 · 运行环境与存储路径</p>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <span class="card-title">系统偏好</span>
        </div>

        <div style="display: flex; flex-direction: column; gap: 12px;">
          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-notifications" ${settings.notifications ? 'checked' : ''}>
            <div>
              <strong>桌面系统通知 (Notifications)</strong>
              ${(state.systemInfo && state.systemInfo.notificationsSupported === false) ? '<span class="status-badge status-neutral" style="margin-left: 6px; font-size: 10px;">仅 .app 支持</span>' : ''}
              <div style="font-size: 11px; color: var(--text-secondary);">仅在重要待办或错误时通知。仅在勾选开启后请求 macOS 通知权限。默认关闭。</div>
            </div>
          </label>

          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-launch-at-login" ${settings.launchAtLogin ? 'checked' : ''}>
            <div>
              <strong>开机启动 (Launch at Login)</strong>
              ${(state.systemInfo && (state.systemInfo.launchAtLoginStatus === 'pending_approval' || state.systemInfo.launchAtLoginStatus === 'requiresApproval')) ? '<span class="status-badge status-amber" style="margin-left: 6px; font-size: 10px;">待系统审批</span>' : ''}
              <div style="font-size: 11px; color: var(--text-secondary);">登录系统时在后台启动状态栏驻留。需 macOS 13+ ServiceManagement 支持。${(state.systemInfo && (state.systemInfo.launchAtLoginStatus === 'pending_approval' || state.systemInfo.launchAtLoginStatus === 'requiresApproval')) ? '（已向系统申请，请在 macOS 系统设置 -> 通用 -> 登录项中允许）' : ''}</div>
            </div>
          </label>

          <label class="form-checkbox-label">
            <input type="checkbox" id="setting-analysis" ${settings.analysisEnabled ? 'checked' : ''}>
            <div>
              <strong>后台证据分析 (Continuous Analysis)</strong>
              <div style="font-size: 11px; color: var(--text-secondary);">在后台定期检查新增会话，进行确定性证据分析。</div>
            </div>
          </label>
        </div>

        <div style="margin-top: 14px; padding-top: 12px; border-top: 1px solid var(--border-color); display: flex; justify-content: flex-end;">
          <button id="btn-save-settings" class="btn btn-primary btn-sm">保存设置</button>
        </div>
      </div>

      <div class="card" style="margin-top: 14px;">
        <div class="card-header">
          <span class="card-title">本地优先与隐私声明 (Local-first)</span>
          <span class="status-badge status-sage">无遥测 (Zero Telemetry)</span>
        </div>
        <ul style="padding-left: 18px; font-size: 12px; line-height: 1.6; color: var(--text-secondary);">
          <li><strong>当前存储路径：</strong><code class="code-badge">${escapeHtml(state.systemInfo.home)}</code> (Channel: ${escapeHtml(state.systemInfo.channel)})</li>
          <li><strong>无云端账户：</strong>Vela 不需要登录注册，无需联网认证。</li>
          <li><strong>数据本地留存：</strong>所有会话索引、Memory、工作流与运行记录存放在本地设备。</li>
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
          <div>自动云端同步: <span class="status-badge status-neutral">不支持（完全离线）</span></div>
        </div>
      </div>
    `;

    const notifCb = document.getElementById('setting-notifications');
    const loginCb = document.getElementById('setting-launch-at-login');
    const analysisCb = document.getElementById('setting-analysis');

    const updateDraft = () => {
      state.settingsDraft = {
        notifications: notifCb.checked,
        launchAtLogin: loginCb.checked,
        analysisEnabled: analysisCb.checked
      };
    };
    notifCb.addEventListener('change', updateDraft);
    loginCb.addEventListener('change', updateDraft);
    analysisCb.addEventListener('change', updateDraft);

    document.getElementById('btn-save-settings').addEventListener('click', async () => {
      const notifications = notifCb.checked;
      const launchAtLogin = loginCb.checked;
      const analysisEnabled = analysisCb.checked;

      try {
        await callBridge('settings.save', {
          notifications,
          launchAtLogin,
          analysisEnabled
        });
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

    openModal('搜索本地项目上下文 (Search)', modalBody, '');

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
                  <strong style="font-size: 12px; color: var(--text-primary);">${escapeHtml(item.title || item.id)}</strong>
                  <span class="code-badge">${escapeHtml(item.kind || 'evidence')}</span>
                </div>
                <div style="font-size: 11px; color: var(--text-secondary); line-height: 1.5; word-break: break-word;">${escapeHtml(item.content || item.description || '')}</div>
                ${item.project ? `<div style="font-size: 10px; color: var(--text-muted); margin-top: 4px; font-family: var(--font-mono);">${escapeHtml(item.project)}</div>` : ''}
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
                    <div style="font-size: 12px; line-height: 1.6; white-space: pre-wrap; word-break: break-word; color: var(--text-primary);">
                      ${escapeHtml(item.content || item.description || '(无详细文本)')}
                    </div>
                  </div>
                  ${item.project ? `
                    <div class="card" style="font-size: 11px;">
                      <div class="text-secondary" style="margin-bottom: 4px;">所属工程路径:</div>
                      <code class="code-badge">${escapeHtml(item.project)}</code>
                    </div>
                  ` : ''}
                  ${item.sourceFile ? `
                    <div class="card" style="font-size: 11px;">
                      <div class="text-secondary" style="margin-bottom: 4px;">来源文件:</div>
                      <code class="code-badge">${escapeHtml(item.sourceFile)}</code>
                    </div>
                  ` : ''}
                  ${item.metadata ? `
                    <div class="card">
                      <div class="card-header"><span class="card-title">元数据</span></div>
                      <div class="code-view" style="font-size: 10px;">${escapeHtml(typeof item.metadata === 'object' ? JSON.stringify(item.metadata, null, 2) : String(item.metadata))}</div>
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
  // DRAWER & MODAL HELPERS
  // -------------------------------------------------------------------------
  function openDrawer(title, subtitle = '') {
    const drawer = document.getElementById('detail-drawer');
    const backdrop = document.getElementById('drawer-backdrop');
    setDrawerTitle(title, subtitle);
    setDrawerCustomActions('');
    if (drawer) drawer.classList.remove('hidden');
    if (backdrop) backdrop.classList.remove('hidden');
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
    state.selectedSessionId = null;
    state.selectedRunId = null;
    state.selectedSuggestionId = null;
    state.selectedEvalId = null;
  }

  function openModal(title, bodyHtml, footerHtml = '') {
    const modal = document.getElementById('modal-container');
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
  }

  function closeModal() {
    const modal = document.getElementById('modal-container');
    if (modal) modal.classList.add('hidden');
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
