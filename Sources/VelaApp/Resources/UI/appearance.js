/**
 * Vela Standalone Appearance Module — appearance.js
 * Authoritative manager for Theme (light/dark/system), Density (standard/compact),
 * and Typography Scaling (90%-150%).
 * 
 * Complies with native WKWebView contracts, ADR 0049, Content Security Policy,
 * and WAI-ARIA Radio Group keyboard navigation with serialized persistence.
 */
(function(window) {
  'use strict';

  // Localization dictionary
  const I18N = {
    'zh-CN': {
      appearanceTitle: '外观与显示',
      appearanceSubtitle: '自适应系统外观、密度与缩放比例，保障伴随小窗与工作台可读性',
      themeTitle: '色彩主题',
      themeDesc: '自动跟随系统或手动锁定界面主题',
      themeSystem: '跟随系统',
      themeLight: '浅色模式',
      themeDark: '深色模式',
      densityTitle: '信息排版密度',
      densityDesc: '紧凑模式适合小屏伴随窗口，标准模式适合宽屏工程阅读',
      densityStandard: '标准间距',
      densityCompact: '紧凑密度',
      scaleTitle: '界面与文字缩放',
      scaleDesc: '等比缩放应用字体与间距 (90% - 150%)',
      previewTitle: '效果实时预览',
      previewActive: '运行中',
      sampleBadge: '示例 / SAMPLE',
      sampleTitle: '重构会话索引与自动化工作流',
      sampleDesc: '本地工程服务就绪 · 5 个运行中轮次 · 审批通道已连通',
      statusSaving: '正在保存偏好...',
      statusSaved: '设置已生效',
      statusFailed: '保存失败，已恢复原设置'
    },
    'en': {
      appearanceTitle: 'Appearance & Display',
      appearanceSubtitle: 'Configure theme, layout density, and typography scaling for optimal readability',
      themeTitle: 'Theme',
      themeDesc: 'Automatically follow macOS appearance or lock to light / dark',
      themeSystem: 'System',
      themeLight: 'Light',
      themeDark: 'Dark',
      densityTitle: 'Layout Density',
      densityDesc: 'Compact density suits narrow sidecars; standard suits wide workspaces',
      densityStandard: 'Standard',
      densityCompact: 'Compact',
      scaleTitle: 'Interface Scaling',
      scaleDesc: 'Proportionally scale interface typography and spacing (90% - 150%)',
      previewTitle: 'Live Preview',
      previewActive: 'Active',
      sampleBadge: 'SAMPLE',
      sampleTitle: 'Refactor session index & automated workflows',
      sampleDesc: 'Local service ready · 5 active turns · Approval channel connected',
      statusSaving: 'Saving preferences...',
      statusSaved: 'Preferences confirmed',
      statusFailed: 'Failed to save, reverted'
    }
  };

  function getLang() {
    if (window.VelaI18n && typeof window.VelaI18n.getLocale === 'function') {
      const loc = window.VelaI18n.getLocale();
      return (loc && loc.startsWith('zh')) ? 'zh-CN' : 'en';
    }
    const docLang = document.documentElement.lang;
    return (docLang && docLang.startsWith('zh')) ? 'zh-CN' : 'en';
  }

  function t(key) {
    const lang = getLang();
    return (I18N[lang] && I18N[lang][key]) || (I18N['zh-CN'] && I18N['zh-CN'][key]) || key;
  }

  // Authoritative confirmed settings received from native host / persistence
  let confirmedSettings = {
    theme: 'system',
    density: 'standard',
    zoomPercent: 100
  };

  let mediaQueryList = null;
  let mediaQueryHandler = null;
  let activeMountInstance = null;

  /**
   * Resolve system theme against window.matchMedia
   */
  function resolveSystemTheme() {
    if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
      return 'dark';
    }
    return 'light';
  }

  /**
   * Normalize an incoming appearance settings patch
   */
  function normalizeSettings(raw) {
    const src = raw || {};
    let theme = src.theme;
    if (theme !== 'light' && theme !== 'dark' && theme !== 'system') {
      theme = confirmedSettings.theme || 'system';
    }

    let density = src.density;
    if (density !== 'standard' && density !== 'compact') {
      density = confirmedSettings.density || 'standard';
    }

    let zoomPercent = Number(src.zoomPercent);
    if (!Number.isFinite(zoomPercent) || zoomPercent < 90 || zoomPercent > 150) {
      zoomPercent = confirmedSettings.zoomPercent || 100;
    }

    return { theme, density, zoomPercent };
  }

  /**
   * Pure DOM application of settings without altering confirmed state
   */
  function applyDom(settings) {
    if (!settings) return;
    const theme = settings.theme || 'system';
    const density = settings.density || 'standard';
    const zoom = Number(settings.zoomPercent) || 100;

    // 1. Theme application
    if (theme === 'system') {
      const resolved = resolveSystemTheme();
      document.documentElement.setAttribute('data-theme', resolved);

      // Manage matchMedia listener
      if (!mediaQueryList && window.matchMedia) {
        mediaQueryList = window.matchMedia('(prefers-color-scheme: dark)');
        mediaQueryHandler = (e) => {
          if (confirmedSettings.theme === 'system') {
            document.documentElement.setAttribute('data-theme', e.matches ? 'dark' : 'light');
          }
        };
        if (typeof mediaQueryList.addEventListener === 'function') {
          mediaQueryList.addEventListener('change', mediaQueryHandler);
        } else if (typeof mediaQueryList.addListener === 'function') {
          mediaQueryList.addListener(mediaQueryHandler);
        }
      }
    } else {
      document.documentElement.setAttribute('data-theme', theme);
      if (mediaQueryList && mediaQueryHandler) {
        if (typeof mediaQueryList.removeEventListener === 'function') {
          mediaQueryList.removeEventListener('change', mediaQueryHandler);
        } else if (typeof mediaQueryList.removeListener === 'function') {
          mediaQueryList.removeListener(mediaQueryHandler);
        }
        mediaQueryList = null;
        mediaQueryHandler = null;
      }
    }

    // 2. Density application
    document.documentElement.setAttribute('data-density', density === 'compact' ? 'compact' : 'standard');

    // 3. Scale application: ONLY update --ui-scale; do NOT multiply with root font-size
    const scaleFactor = Math.max(0.9, Math.min(1.5, zoom / 100));
    document.documentElement.style.setProperty('--ui-scale', String(scaleFactor));
  }

  /**
   * Public authoritative application of settings:
   * Sets DOM and records confirmed state as the baseline.
   * If a mount is active, synchronizes its mounted controls.
   */
  function apply(settings) {
    confirmedSettings = normalizeSettings(settings);
    applyDom(confirmedSettings);

    if (activeMountInstance && !activeMountInstance.isDisposed && activeMountInstance.isMounted()) {
      activeMountInstance.syncToConfirmed(confirmedSettings);
    }
  }

  /**
   * Mount Appearance Settings UI inside the target container
   * @param {HTMLElement} container
   * @param {Object} options { settings, save: async Function, onError: Function }
   * @returns {Object} { dispose: Function }
   */
  function mount(container, options) {
    if (!container) return { dispose: () => {} };

    // Dispose previous mount if present
    if (activeMountInstance) {
      activeMountInstance.dispose();
    }

    const opts = options || {};
    if (typeof opts.save !== 'function') {
      throw new TypeError('VelaAppearance.mount requires an asynchronous save callback');
    }
    const saveCallback = opts.save;
    const onErrorCallback = typeof opts.onError === 'function' ? opts.onError : (err) => console.error(err);

    // Mount-scoped state
    let isDisposed = false;
    let displayedState = Object.assign({}, confirmedSettings, normalizeSettings(opts.settings));

    // Serialization queue
    let isSaving = false;
    let pendingPatch = null;
    let requestSeq = 0;

    // Render HTML structure
    container.innerHTML = `
      <div class="card appearance-panel">
        <div class="card-header">
          <div>
            <h3 class="card-title">${escapeText(t('appearanceTitle'))}</h3>
            <p class="section-sub" style="margin: 4px 0 0;">${escapeText(t('appearanceSubtitle'))}</p>
          </div>
          <span id="appearance-status" class="quiet-tag is-plain" aria-live="polite" style="font-size: 11px;"></span>
        </div>

        <!-- 1. Theme Selection -->
        <div class="appearance-section">
          <label class="appearance-section-title">${escapeText(t('themeTitle'))}</label>
          <span class="appearance-section-desc">${escapeText(t('themeDesc'))}</span>
          <div class="appearance-options-grid" id="appearance-theme-group" role="radiogroup" aria-label="${escapeText(t('themeTitle'))}">
            <div class="appearance-option-card" data-appearance-theme="system" role="radio" tabindex="-1">
              <div class="appearance-swatch-box appearance-swatch-system"></div>
              <span class="appearance-option-label">${escapeText(t('themeSystem'))}</span>
            </div>
            <div class="appearance-option-card" data-appearance-theme="light" role="radio" tabindex="-1">
              <div class="appearance-swatch-box appearance-swatch-light"></div>
              <span class="appearance-option-label">${escapeText(t('themeLight'))}</span>
            </div>
            <div class="appearance-option-card" data-appearance-theme="dark" role="radio" tabindex="-1">
              <div class="appearance-swatch-box appearance-swatch-dark"></div>
              <span class="appearance-option-label">${escapeText(t('themeDark'))}</span>
            </div>
          </div>
        </div>

        <!-- 2. Density Selection -->
        <div class="appearance-section">
          <label class="appearance-section-title">${escapeText(t('densityTitle'))}</label>
          <span class="appearance-section-desc">${escapeText(t('densityDesc'))}</span>
          <div class="appearance-options-grid" id="appearance-density-group" role="radiogroup" aria-label="${escapeText(t('densityTitle'))}">
            <div class="appearance-option-card" data-appearance-density="standard" role="radio" tabindex="-1">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/></svg>
              <span class="appearance-option-label">${escapeText(t('densityStandard'))}</span>
            </div>
            <div class="appearance-option-card" data-appearance-density="compact" role="radio" tabindex="-1">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="3" width="18" height="4" rx="1"/><rect x="3" y="10" width="18" height="4" rx="1"/><rect x="3" y="17" width="18" height="4" rx="1"/></svg>
              <span class="appearance-option-label">${escapeText(t('densityCompact'))}</span>
            </div>
          </div>
        </div>

        <!-- 3. Scale Selection -->
        <div class="appearance-section">
          <label class="appearance-section-title">${escapeText(t('scaleTitle'))}</label>
          <span class="appearance-section-desc">${escapeText(t('scaleDesc'))}</span>
          <div class="appearance-scale-buttons" id="appearance-scale-group" role="radiogroup" aria-label="${escapeText(t('scaleTitle'))}">
            ${[90, 100, 110, 125, 150].map(z => `
              <button type="button" class="appearance-scale-btn" data-appearance-zoom="${z}" role="radio" tabindex="-1">
                ${z}%
              </button>
            `).join('')}
          </div>
        </div>

        <!-- 4. Synthetic Live Preview Box -->
        <div class="appearance-section">
          <label class="appearance-section-title">${escapeText(t('previewTitle'))}</label>
          <div class="appearance-preview-card">
            <div class="appearance-preview-header">
              <span class="appearance-sample-badge">${escapeText(t('sampleBadge'))}</span>
              <span class="status-badge status-sage">${escapeText(t('previewActive'))}</span>
            </div>
            <h4 style="font-size: var(--font-heading-sm); margin: 6px 0 4px; font-weight: 600;">${escapeText(t('sampleTitle'))}</h4>
            <p style="font-size: var(--font-meta); color: var(--text-secondary); margin: 0;">${escapeText(t('sampleDesc'))}</p>
          </div>
        </div>
      </div>
    `;

    const statusEl = container.querySelector('#appearance-status');

    function isConnected() {
      return !isDisposed && container && container.isConnected && document.contains(container);
    }

    function setStatus(msg, isError) {
      if (!statusEl || !isConnected()) return;
      statusEl.textContent = msg;
      statusEl.style.color = isError ? 'var(--status-red-text)' : 'var(--text-muted)';
    }

    /**
     * Synchronize controls to target state, setting classes, aria-checked, and roving tabIndex
     */
    function updateControlsUI(targetState) {
      if (!isConnected()) return;

      // Theme
      container.querySelectorAll('[data-appearance-theme]').forEach(el => {
        const isSel = el.getAttribute('data-appearance-theme') === targetState.theme;
        el.classList.toggle('selected', isSel);
        el.setAttribute('aria-checked', String(isSel));
        el.setAttribute('tabindex', isSel ? '0' : '-1');
      });

      // Density
      container.querySelectorAll('[data-appearance-density]').forEach(el => {
        const isSel = el.getAttribute('data-appearance-density') === targetState.density;
        el.classList.toggle('selected', isSel);
        el.setAttribute('aria-checked', String(isSel));
        el.setAttribute('tabindex', isSel ? '0' : '-1');
      });

      // Zoom
      container.querySelectorAll('[data-appearance-zoom]').forEach(el => {
        const isSel = Number(el.getAttribute('data-appearance-zoom')) === targetState.zoomPercent;
        el.classList.toggle('selected', isSel);
        el.setAttribute('aria-checked', String(isSel));
        el.setAttribute('tabindex', isSel ? '0' : '-1');
      });
    }

    // Initialize controls to displayedState
    updateControlsUI(displayedState);

    /**
     * Serialized save processor
     */
    async function processQueue() {
      if (isSaving || !pendingPatch || !isConnected()) return;

      isSaving = true;
      const patchToSend = Object.assign({}, pendingPatch);
      pendingPatch = null;
      const currentSeq = ++requestSeq;

      setStatus(t('statusSaving'), false);

      try {
        // Enforce ONLY appearance keys in patch
        const safePatch = {
          theme: patchToSend.theme,
          density: patchToSend.density,
          zoomPercent: patchToSend.zoomPercent
        };

        const result = await saveCallback(safePatch);

        if (!isConnected() || currentSeq !== requestSeq) {
          isSaving = false;
          if (pendingPatch) processQueue();
          return;
        }

        // Apply normalized confirmed returned values
        const confirmed = normalizeSettings(result || safePatch);
        confirmedSettings = confirmed;
        displayedState = Object.assign({}, confirmed);
        applyDom(confirmed);
        updateControlsUI(confirmed);

        setStatus(t('statusSaved'), false);
        setTimeout(() => {
          if (isConnected() && currentSeq === requestSeq) {
            setStatus('', false);
          }
        }, 2500);
      } catch (err) {
        if (!isConnected() || currentSeq !== requestSeq) {
          isSaving = false;
          return;
        }

        console.error('VelaAppearance save failed:', err);
        setStatus(t('statusFailed'), true);

        // Roll back to the last real confirmed settings
        displayedState = Object.assign({}, confirmedSettings);
        applyDom(confirmedSettings);
        updateControlsUI(confirmedSettings);

        onErrorCallback(err);
      } finally {
        isSaving = false;
        if (pendingPatch && isConnected()) {
          processQueue();
        }
      }
    }

    /**
     * Queue a user change, update optimistic preview immediately
     */
    function queueChange(patch) {
      if (!isConnected()) return;

      // Update displayed state optimistically
      displayedState = normalizeSettings(Object.assign({}, displayedState, patch));
      applyDom(displayedState);
      updateControlsUI(displayedState);

      // Coalesce into pending patch
      pendingPatch = Object.assign(pendingPatch || {}, patch);

      processQueue();
    }

    /**
     * Wire WAI-ARIA roving tabIndex and arrow key navigation for a radio group
     */
    function bindRadioGroup(groupSelector, attrName, valueParser, isNumeric) {
      const groupEl = container.querySelector(groupSelector);
      if (!groupEl) return;

      const items = Array.from(groupEl.querySelectorAll(`[${attrName}]`));
      if (!items.length) return;

      items.forEach((item, index) => {
        // Click
        item.addEventListener('click', () => {
          const rawVal = item.getAttribute(attrName);
          const val = isNumeric ? Number(rawVal) : rawVal;
          queueChange({ [valueParser]: val });
          item.focus();
        });

        // Keyboard navigation (ArrowLeft/Up, ArrowRight/Down, Home, End, Enter/Space)
        item.addEventListener('keydown', (e) => {
          let targetIndex = -1;
          if (e.key === 'ArrowRight' || e.key === 'ArrowDown') {
            targetIndex = (index + 1) % items.length;
          } else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') {
            targetIndex = (index - 1 + items.length) % items.length;
          } else if (e.key === 'Home') {
            targetIndex = 0;
          } else if (e.key === 'End') {
            targetIndex = items.length - 1;
          } else if (e.key === ' ' || e.key === 'Enter') {
            e.preventDefault();
            const rawVal = item.getAttribute(attrName);
            const val = isNumeric ? Number(rawVal) : rawVal;
            queueChange({ [valueParser]: val });
            return;
          }

          if (targetIndex >= 0) {
            e.preventDefault();
            const targetItem = items[targetIndex];
            const rawVal = targetItem.getAttribute(attrName);
            const val = isNumeric ? Number(rawVal) : rawVal;
            queueChange({ [valueParser]: val });
            targetItem.focus();
          }
        });
      });
    }

    bindRadioGroup('#appearance-theme-group', 'data-appearance-theme', 'theme', false);
    bindRadioGroup('#appearance-density-group', 'data-appearance-density', 'density', false);
    bindRadioGroup('#appearance-scale-group', 'data-appearance-zoom', 'zoomPercent', true);

    const instance = {
      isDisposed: false,
      isMounted: () => isConnected(),
      syncToConfirmed: (confirmed) => {
        if (!isConnected()) return;
        displayedState = Object.assign({}, confirmed);
        updateControlsUI(displayedState);
      },
      dispose: () => {
        isDisposed = true;
        pendingPatch = null;
        if (activeMountInstance === instance) {
          activeMountInstance = null;
        }
      }
    };

    activeMountInstance = instance;
    return { dispose: instance.dispose };
  }

  function escapeText(str) {
    if (!str) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Dynamic --shell-height observer for narrow drawer top alignment
  function initShellHeightObserver() {
    if (typeof ResizeObserver === 'undefined') return;

    function update() {
      const titlebar = document.querySelector('.window-titlebar');
      const companionShell = document.querySelector('.companion-shell');
      let h = 0;
      if (titlebar && titlebar.offsetHeight) h += titlebar.offsetHeight;
      if (companionShell && companionShell.offsetHeight) {
        const st = window.getComputedStyle(companionShell);
        if (st.display !== 'none' && st.visibility !== 'hidden') {
          h += companionShell.offsetHeight;
        }
      }
      if (h > 0) {
        document.documentElement.style.setProperty('--shell-height', `${h}px`);
      }
    }

    const ro = new ResizeObserver(update);
    const start = () => {
      const titlebar = document.querySelector('.window-titlebar');
      const companionShell = document.querySelector('.companion-shell');
      if (titlebar) ro.observe(titlebar);
      if (companionShell) ro.observe(companionShell);
      update();
    };

    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', start);
    } else {
      start();
    }
    window.addEventListener('resize', update);
  }

  initShellHeightObserver();

  // Export public module
  window.VelaAppearance = {
    apply,
    mount,
    getConfirmed: () => Object.assign({}, confirmedSettings)
  };

})(window);
