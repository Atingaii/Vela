/**
 * Vela Official Website Interactions (site.js)
 * Production vanilla JavaScript:
 * - Persistent Light/Dark theme switching via guarded localStorage (default Light)
 * - Accessible lightweight mobile navigation dropdown with aria-controls, focus management,
 *   Escape key support, outside click closing, and resize reset
 * - Native clipboard copy buttons with visual and accessible feedback
 * - No external dependencies, trackers, or remote network calls
 */

(function() {
  'use strict';

  // SVG Icons for Theme Toggle
  const MOON_ICON = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>';
  const SUN_ICON = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg>';

  // Check saved theme or default to light
  function getPreferredTheme() {
    try {
      const savedTheme = localStorage.getItem('vela-theme');
      if (savedTheme === 'dark' || savedTheme === 'light') {
        return savedTheme;
      }
    } catch (e) {
      // Ignore localStorage access restrictions
    }
    return 'light'; // Default LIGHT as strictly specified in brief
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    const themeToggleButtons = document.querySelectorAll('.theme-toggle-btn');
    themeToggleButtons.forEach(btn => {
      btn.innerHTML = theme === 'dark' ? SUN_ICON : MOON_ICON;
      const label = theme === 'dark' ? '切换为浅色模式' : '切换为深色模式';
      btn.setAttribute('aria-label', label);
      btn.setAttribute('title', label);
    });
  }

  function initTheme() {
    const currentTheme = getPreferredTheme();
    applyTheme(currentTheme);

    const themeToggleButtons = document.querySelectorAll('.theme-toggle-btn');
    themeToggleButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        const now = document.documentElement.getAttribute('data-theme') || 'light';
        const next = now === 'dark' ? 'light' : 'dark';
        applyTheme(next);
        try {
          localStorage.setItem('vela-theme', next);
        } catch (e) {
          // Ignore
        }
      });
    });
  }

  // Accessible Mobile Navigation Dropdown
  function initMobileMenu() {
    const toggle = document.querySelector('.mobile-menu-toggle');
    const panel = document.getElementById('mobile-nav-panel');
    if (!toggle || !panel) return;

    function openMenu() {
      toggle.setAttribute('aria-expanded', 'true');
      panel.classList.add('open');
      // Do NOT lock body overflow: this is a compact dropdown, not a full-screen modal
      const firstLink = panel.querySelector('a');
      if (firstLink) {
        firstLink.focus();
      }
    }

    function closeMenu(restoreFocus) {
      toggle.setAttribute('aria-expanded', 'false');
      panel.classList.remove('open');
      if (restoreFocus) {
        toggle.focus();
      }
    }

    toggle.addEventListener('click', (e) => {
      e.stopPropagation();
      const isExpanded = toggle.getAttribute('aria-expanded') === 'true';
      if (isExpanded) {
        closeMenu(true);
      } else {
        openMenu();
      }
    });

    // Close on navigation link click without stealing focus from navigation
    panel.querySelectorAll('a').forEach(link => {
      link.addEventListener('click', () => {
        closeMenu(false);
      });
    });

    // Close on Escape key and restore focus to toggle button
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && toggle.getAttribute('aria-expanded') === 'true') {
        closeMenu(true);
      }
    });

    // Close when clicking outside menu and toggle
    document.addEventListener('click', (e) => {
      if (toggle.getAttribute('aria-expanded') === 'true' && !panel.contains(e.target) && !toggle.contains(e.target)) {
        closeMenu(false);
      }
    });

    // Close when focus leaves the menu panel
    panel.addEventListener('focusout', () => {
      requestAnimationFrame(() => {
        if (toggle.getAttribute('aria-expanded') === 'true' &&
            !panel.contains(document.activeElement) &&
            document.activeElement !== toggle) {
          closeMenu(false);
        }
      });
    });

    // Close if viewport grows beyond 768px (so desktop nav never remains locked)
    window.addEventListener('resize', () => {
      if (window.innerWidth > 768 && toggle.getAttribute('aria-expanded') === 'true') {
        closeMenu(false);
      }
    });
  }

  // Copy to Clipboard Utility
  function copyTextToClipboard(text, onSuccess, onError) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text)
        .then(onSuccess)
        .catch(() => {
          fallbackCopy(text, onSuccess, onError);
        });
    } else {
      fallbackCopy(text, onSuccess, onError);
    }
  }

  function fallbackCopy(text, onSuccess, onError) {
    try {
      const textarea = document.createElement('textarea');
      textarea.value = text;
      textarea.style.position = 'fixed';
      textarea.style.top = '0';
      textarea.style.left = '0';
      textarea.style.opacity = '0';
      document.body.appendChild(textarea);
      textarea.focus();
      textarea.select();
      const successful = document.execCommand('copy');
      document.body.removeChild(textarea);
      if (successful) {
        if (onSuccess) onSuccess();
      } else {
        if (onError) onError();
      }
    } catch (err) {
      if (onError) onError();
    }
  }

  function initCopyButtons() {
    const copyButtons = document.querySelectorAll('[data-copy-text], [data-copy-target]');
    copyButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        let text = btn.getAttribute('data-copy-text');
        const targetSelector = btn.getAttribute('data-copy-target');
        if (!text && targetSelector) {
          const targetEl = document.querySelector(targetSelector);
          if (targetEl) text = targetEl.textContent.trim();
        }

        if (!text) return;

        const originalHtml = btn.innerHTML;

        copyTextToClipboard(text, () => {
          btn.classList.add('copied');
          btn.setAttribute('aria-live', 'polite');
          btn.textContent = '已复制';

          setTimeout(() => {
            btn.classList.remove('copied');
            btn.innerHTML = originalHtml;
          }, 2000);
        }, () => {
          btn.textContent = '复制失败';
          setTimeout(() => {
            btn.innerHTML = originalHtml;
          }, 2000);
        });
      });
    });
  }

  // Collapsible Mobile Documentation TOC
  function initDocsToc() {
    const toggle = document.querySelector('.docs-toc-toggle');
    const content = document.getElementById('docs-toc-content');
    if (!toggle || !content) return;

    function openToc() {
      toggle.setAttribute('aria-expanded', 'true');
      const hint = toggle.querySelector('.docs-toc-toggle-hint');
      if (hint) hint.textContent = '收起 ▴';
      const firstLink = content.querySelector('a');
      if (firstLink) {
        firstLink.focus();
      }
    }

    function closeToc(restoreFocus) {
      toggle.setAttribute('aria-expanded', 'false');
      const hint = toggle.querySelector('.docs-toc-toggle-hint');
      if (hint) hint.textContent = '展开 ▾';
      if (restoreFocus) {
        toggle.focus();
      }
    }

    toggle.addEventListener('click', (e) => {
      e.stopPropagation();
      const isExpanded = toggle.getAttribute('aria-expanded') === 'true';
      if (isExpanded) {
        closeToc(true);
      } else {
        openToc();
      }
    });

    // Close and jump when a nav link is clicked on mobile
    content.querySelectorAll('a').forEach(link => {
      link.addEventListener('click', () => {
        if (window.innerWidth <= 1024) {
          closeToc(false);
        }
      });
    });

    // Close on Escape key
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && window.innerWidth <= 1024 && toggle.getAttribute('aria-expanded') === 'true') {
        closeToc(true);
      }
    });

    // Close on outside click
    document.addEventListener('click', (e) => {
      if (window.innerWidth <= 1024 && toggle.getAttribute('aria-expanded') === 'true' && !content.contains(e.target) && !toggle.contains(e.target)) {
        closeToc(false);
      }
    });

    // Reset when window resized beyond 1024px
    window.addEventListener('resize', () => {
      if (window.innerWidth > 1024 && toggle.getAttribute('aria-expanded') === 'true') {
        closeToc(false);
      }
    });
  }

  // Comparisons Page Factor Matrix & Details Interaction
  function initComparisonsPage() {
    const expandAllBtn = document.getElementById('btn-expand-all');
    const collapseAllBtn = document.getElementById('btn-collapse-all');
    const detailCards = document.querySelectorAll('.factor-detail-card');

    if (expandAllBtn && collapseAllBtn) {
      expandAllBtn.addEventListener('click', () => {
        detailCards.forEach(card => card.setAttribute('open', ''));
      });
      collapseAllBtn.addEventListener('click', () => {
        detailCards.forEach(card => card.removeAttribute('open'));
      });
    }

    // When clicking a factor link in the comparison table, open the target detail card
    document.querySelectorAll('.factor-link').forEach(link => {
      link.addEventListener('click', () => {
        const hash = link.getAttribute('href');
        if (hash && hash.startsWith('#')) {
          const targetCard = document.querySelector(hash);
          if (targetCard && targetCard.tagName.toLowerCase() === 'details') {
            targetCard.setAttribute('open', '');
          }
        }
      });
    });

    // Also handle direct hash load or back/forward
    function handleHashOpen() {
      if (window.location.hash) {
        try {
          const target = document.querySelector(window.location.hash);
          if (target && target.tagName.toLowerCase() === 'details') {
            target.setAttribute('open', '');
          }
        } catch (e) {}
      }
    }
    window.addEventListener('hashchange', handleHashOpen);
    handleHashOpen();
  }

  // Accessible Category Filter for Usecases Catalogue
  function initUsecasesFilter() {
    const filterButtons = document.querySelectorAll('.catalogue-pill[data-filter]');
    const taskRows = document.querySelectorAll('.usecases-table tbody tr[data-category]');
    const statusEl = document.getElementById('filter-status');
    if (!filterButtons.length || !taskRows.length) return;

    filterButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        const filter = btn.getAttribute('data-filter');

        // Update aria-pressed and active state
        filterButtons.forEach(b => {
          const isActive = (b === btn);
          b.classList.toggle('active', isActive);
          b.setAttribute('aria-pressed', isActive ? 'true' : 'false');
        });

        // Filter task rows and track visible count
        let visibleCount = 0;
        taskRows.forEach(row => {
          const cat = row.getAttribute('data-category');
          const shouldShow = (filter === 'all' || cat === filter);
          row.style.display = shouldShow ? '' : 'none';
          if (shouldShow) visibleCount++;
        });

        // Update localized live status text
        if (statusEl) {
          statusEl.textContent = `显示 ${visibleCount} / 4 个场景`;
        }
      });
    });
  }

  // Initialize on DOM Ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      initTheme();
      initMobileMenu();
      initCopyButtons();
      initDocsToc();
      initComparisonsPage();
      initUsecasesFilter();
    });
  } else {
    initTheme();
    initMobileMenu();
    initCopyButtons();
    initDocsToc();
    initComparisonsPage();
    initUsecasesFilter();
  }
})();
