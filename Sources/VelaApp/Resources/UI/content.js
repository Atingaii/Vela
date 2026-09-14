/* Local, bounded rich content. All provider/project text is untrusted. */
(function () {
  'use strict';
  window.Prism = window.Prism || {};
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const label = key => window.VelaI18n ? window.VelaI18n.t('reading.' + key) : key;
  const textLabel = key => `<span data-i18n="reading.${key}">${escape(label(key))}</span>`;
  // Original small SVG vocabulary; no icon font, network dependency or randomized variants.
  const iconPaths = {
    workflow:'<rect x="3" y="3" width="6" height="6" rx="2"/><rect x="15" y="15" width="6" height="6" rx="2"/><path d="M9 6h6a3 3 0 0 1 3 3v6M6 9v6a3 3 0 0 0 3 3h6"/>',
    skill:'<rect x="5" y="4" width="14" height="16" rx="3"/><path d="m9 9-2 3 2 3m6-6 2 3-2 3m-2-7-2 8"/>',
    rule:'<path d="M9 5h11M9 12h11M9 19h11M3 5l1 1 2-2m-3 8 1 1 2-2m-3 8 1 1 2-2"/>',
    hook:'<path d="M7 4v9a5 5 0 0 0 10 0V9M14 12l3-3 3 3"/><circle cx="7" cy="4" r="2"/>',
    connector:'<path d="m8 3 2 4m6-4-2 4M7 7h10v4a5 5 0 0 1-10 0V7Zm5 9v5"/>',
    book:'<path d="M4 19a2 2 0 0 1 2-2h14M6 3h14v18H6a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Zm2 4h8m-8 4h6"/>',
    branch:'<circle cx="6" cy="5" r="2"/><circle cx="18" cy="6" r="2"/><circle cx="6" cy="19" r="2"/><path d="M6 7v10M18 8c0 6-12 3-12 9"/>',
    document:'<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9Z"/><path d="M14 3v6h6M8 13h8M8 17h5"/>',
    terminal:'<rect x="3" y="4" width="18" height="16" rx="3"/><path d="m7 9 3 3-3 3m6 0h4"/>',
    clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    watch:'<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>',
    globe:'<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
    conversation:'<path d="M5 4h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H9l-6 3V6a2 2 0 0 1 2-2Z"/><path d="M7 9h10M7 13h6"/>',
    play:'<path d="m8 5 11 7-11 7Z"/>',
    preview:'<path d="m5 6 7 6-7 6V6Zm9 0 7 6-7 6"/>',
    edit:'<path d="m15 4 5 5M4 20l5-1L20 8a2 2 0 0 0-5-5L4 14v6Z"/>',
    archive:'<rect x="3" y="3" width="18" height="4" rx="1"/><path d="M5 7v13h14V7M9 11h6"/>',
    folder:'<path d="M3 7V5a2 2 0 0 1 2-2h5l2 3h7a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z"/>',
    chevron:'<path d="m7 10 5 5 5-5"/>'
  };
  function icon(name, className = '') {
    return `<svg class="semantic-icon ${escape(className)}" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${iconPaths[name] || iconPaths.workflow}</svg>`;
  }
  function workflowKind(workflow) {
    if (workflow.trigger === 'cron') return 'clock';
    if (workflow.trigger === 'watch') return 'watch';
    const tools = (Array.isArray(workflow.steps) ? workflow.steps : []).map(step => String(step.tool || ''));
    if (tools.length && tools.every(tool => tool.startsWith('git.'))) return 'branch';
    if (tools.includes('file.write')) return 'document';
    if (tools.some(tool => tool.startsWith('shell.'))) return 'terminal';
    if (tools.some(tool => tool.startsWith('http.'))) return 'globe';
    if (['agent','model','pipeline'].includes(workflow.type) || tools.some(tool => tool.startsWith('agent.'))) return 'conversation';
    return 'workflow';
  }
  const allowedTags = ['p','br','strong','em','del','blockquote','ul','ol','li','h1','h2','h3','h4','h5','h6','hr','pre','code','table','thead','tbody','tr','th','td','span'];
  const clean = html => window.DOMPurify.sanitize(html, {ALLOWED_TAGS: allowedTags, ALLOWED_ATTR: ['class'], ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: false});
  const languages = new Set(['javascript','json','bash','python','swift','css','markup']);
  const aliases = {js:'javascript',ts:'javascript',typescript:'javascript',sh:'bash',shell:'bash',py:'python',html:'markup',xml:'markup'};
  function code(source, language = '') {
    const text = String(source ?? '');
    const lang = aliases[language.toLowerCase()] || language.toLowerCase();
    // Never auto-detect or highlight large/log-like lines. Unknown syntax stays exact plain text.
    let html = escape(text);
    if (text.length <= 24000 && !text.split('\n').some(line => line.length > 2000) && languages.has(lang) && window.Prism?.languages[lang]) {
      try { html = clean(Prism.highlight(text, Prism.languages[lang], lang)); } catch (_) { /* plain fallback */ }
    }
    return `<pre class="reading-code" tabindex="0"><code class="language-${languages.has(lang) ? lang : 'text'}">${html}</code></pre>`;
  }
  function markdown(source) {
    const text = String(source ?? '');
    if (!window.marked || !window.DOMPurify || text.length > 64000 || text.split('\n').some(line => line.length > 8000)) return `<div class="reading-prose">${code(text)}</div>`;
    try {
      const renderer = new marked.Renderer();
      // Raw HTML is literal text; links/images never become navigation or network requests.
      renderer.html = token => escape(token.text);
      renderer.link = function(token) { return this.parser.parseInline(token.tokens); };
      renderer.image = token => escape(token.text || '');
      renderer.code = token => code(token.text, (token.lang || '').split(/\s/)[0]);
      return `<div class="reading-prose">${clean(marked.parse(text, {renderer, gfm:true, breaks:false, async:false}))}</div>`;
    } catch (_) { return `<div class="reading-prose">${code(text)}</div>`; }
  }
  function file(source, filename = '') {
    const text = String(source ?? '');
    const ext = String(filename).split('.').pop().toLowerCase();
    const isMarkdown = ['md','markdown','mdx'].includes(ext);
    // Read prose first; keep the exact source, including front matter, for copying.
    const frontmatter = isMarkdown && text.length <= 64000 ? text.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/) : null;
    const hasMetadata = frontmatter && /^[A-Za-z_][\w-]*:\s/m.test(frontmatter[1]);
    const previewText = hasMetadata ? text.slice(frontmatter[0].length) : text;
    return `<section class="reading-file" data-view="${isMarkdown ? 'preview' : 'source'}">
      <div class="reading-file-toolbar">
        <span class="reading-file-name">${escape(String(filename).split('/').pop() || label('content'))}</span>
        ${isMarkdown ? `<button type="button" class="btn btn-sm btn-ghost reading-preview" aria-pressed="true">${textLabel('preview')}</button><button type="button" class="btn btn-sm btn-ghost reading-source" aria-pressed="false">${textLabel('source')}</button>` : ''}
        <button type="button" class="btn btn-sm btn-ghost reading-copy">${textLabel('copy')}</button>
      </div>
      ${isMarkdown ? `<div class="reading-file-preview">${markdown(previewText)}${hasMetadata ? `<details class="technical-disclosure reading-frontmatter"><summary>${textLabel('metadata')}</summary>${code(frontmatter[1])}</details>` : ''}</div>` : ''}
      <div class="reading-file-source">${code(text, ext)}</div>
      <span class="reading-original" hidden data-source="${escape(JSON.stringify(text))}"></span>
    </section>`;
  }
  function tool(message) {
    const source = String(message.content ?? '');
    const name = String(message.tool || 'tool');
    let input = message.input;
    // Only parse the explicit provider tool envelope; never execute or infer arbitrary prose.
    if (input === undefined && source.length <= 64000) {
      const envelope = source.match(/^\[Tool: ([^\]\n]+)\]\r?\n([\s\S]*)$/);
      if (envelope && envelope[1] === name) input = envelope[2];
    }
    if (typeof input === 'string' && input.length <= 64000) {
      try { input = JSON.parse(input); } catch (_) { /* preserve the original below */ }
    }
    const args = input && typeof input === 'object' && !Array.isArray(input) ? input : {};
    const command = ['exec_command','run_terminal_cmd','Bash','bash','shell'].includes(name)
      ? (typeof args.cmd === 'string' ? args.cmd : typeof args.command === 'string' ? args.command : null) : null;
    const hasOutput = message.output !== undefined && message.output !== null;
    const output = hasOutput ? (typeof message.output === 'string' ? message.output : JSON.stringify(message.output, null, 2)) : '';
    const serializedInput = input === undefined ? '' : typeof input === 'string' ? input : JSON.stringify(input, null, 2);
    const type = command !== null ? 'terminal' : 'workflow';
    const primary = command !== null ? command : serializedInput || source;
    return `<section class="reading-file tool-invocation" data-tool="${escape(name)}" data-view="source">
      <div class="tool-invocation-heading">${icon(type)}<strong>${textLabel(command !== null ? 'recordedCommand' : 'recordedTool')}</strong><span class="tool-name">${escape(name)}</span><button type="button" class="btn btn-sm btn-ghost reading-copy">${textLabel('copy')}</button></div>
      <div class="reading-file-source tool-primary-source">${code(primary, command !== null ? 'bash' : serializedInput ? 'json' : '')}</div>
      <span class="reading-original" hidden data-source="${escape(JSON.stringify(primary))}"></span>
      ${hasOutput ? `<div class="tool-output"><h4>${textLabel('toolOutput')}</h4>${file(output, typeof message.output === 'string' ? 'output.txt' : 'output.json')}</div>` : command !== null ? `<p class="tool-observation-note">${textLabel('resultNotObserved')}</p>` : ''}
      <details class="technical-disclosure tool-raw-record"><summary>${textLabel('rawRecord')}</summary>${file(source, 'record.txt')}${message.input !== undefined ? file(typeof message.input === 'string' ? message.input : JSON.stringify(message.input,null,2), 'input.json') : ''}</details>
    </section>`;
  }
  document.addEventListener('click', async event => {
    const button = event.target.closest('.reading-preview, .reading-source, .reading-copy');
    if (!button) return;
    const viewer = button.closest('.reading-file');
    if (button.classList.contains('reading-copy')) {
      const original = JSON.parse(viewer.querySelector('.reading-original').getAttribute('data-source'));
      try {
        if (navigator.clipboard?.writeText) await navigator.clipboard.writeText(original);
        else {
          const area = document.createElement('textarea'); area.value = original; area.style.cssText='position:fixed;opacity:0'; document.body.append(area); area.select();
          const copied = document.execCommand('copy'); area.remove(); button.focus(); if (!copied) throw Error('copy');
        }
        button.innerHTML = textLabel('copied');
      } catch (_) { button.innerHTML = textLabel('copyFailed'); }
      return;
    }
    const preview = button.classList.contains('reading-preview');
    viewer.dataset.view = preview ? 'preview' : 'source';
    viewer.querySelector('.reading-preview').setAttribute('aria-pressed', String(preview));
    viewer.querySelector('.reading-source').setAttribute('aria-pressed', String(!preview));
  });
  // Viewport-aware disclosure menus. Event-driven only; no observers or polling.
  const openMenus = () => [...document.querySelectorAll('details.action-menu[open]')];
  function closeMenu(menu, restoreFocus = false) {
    menu.open = false;
    menu.querySelector('summary').setAttribute('aria-expanded', 'false');
    if (restoreFocus) menu.querySelector('summary').focus();
  }
  function positionMenu(menu) {
    const panel = menu.querySelector('.action-menu-items');
    const trigger = menu.querySelector('summary');
    if (!panel || !trigger) return;
    trigger.setAttribute('aria-expanded', 'true');
    panel.style.visibility = 'hidden';
    panel.style.maxHeight = `${Math.max(120, innerHeight - 24)}px`;
    const rect = trigger.getBoundingClientRect();
    const width = Math.min(288, innerWidth - 24);
    panel.style.width = `${width}px`;
    const height = panel.getBoundingClientRect().height;
    panel.style.left = `${Math.max(12, Math.min(rect.right - width, innerWidth - width - 12))}px`;
    panel.style.top = `${Math.max(12, Math.min(rect.bottom + 6, innerHeight - height - 12))}px`;
    panel.style.visibility = '';
  }
  document.addEventListener('toggle', event => {
    const menu = event.target;
    if (!menu.matches?.('details.action-menu')) return;
    menu.querySelector('summary').setAttribute('aria-expanded', String(menu.open));
    if (menu.open) {
      openMenus().filter(other => other !== menu).forEach(other => closeMenu(other));
      positionMenu(menu);
    }
  }, true);
  document.addEventListener('click', event => {
    openMenus().forEach(menu => {
      if (!menu.contains(event.target) || event.target.closest('button')) closeMenu(menu);
    });
  });
  document.addEventListener('keydown', event => {
    const menu = event.target.closest('details.action-menu[open]');
    if (!menu) return;
    if (event.key === 'Escape') {
      event.preventDefault(); event.stopImmediatePropagation(); closeMenu(menu, true); return;
    }
    if (['ArrowDown','ArrowUp','Home','End'].includes(event.key)) {
      const items = [...menu.querySelectorAll('.action-menu-items button:not(:disabled)')];
      if (!items.length) return;
      event.preventDefault(); event.stopPropagation();
      const index = items.indexOf(document.activeElement);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? items.length - 1 : event.key === 'ArrowDown' ? (index + 1) % items.length : (index <= 0 ? items.length - 1 : index - 1);
      items[next].focus();
    }
  }, true);
  document.addEventListener('focusin', event => openMenus().forEach(menu => { if (!menu.contains(event.target)) closeMenu(menu); }));
  document.addEventListener('scroll', event => {
    if (!event.target.closest?.('.action-menu-items')) openMenus().forEach(menu => closeMenu(menu));
  }, true);
  window.addEventListener('resize', () => openMenus().forEach(positionMenu));
  document.addEventListener('DOMContentLoaded', () => {
    const toggle = document.getElementById('btn-toggle-sidebar');
    toggle?.addEventListener('click', () => {
      const collapsed = document.body.classList.toggle('sidebar-collapsed');
      toggle.setAttribute('aria-expanded', String(!collapsed));
      const sidebar = document.getElementById('workspace-sidebar');
      if (sidebar) sidebar.inert = collapsed;
    });
    document.getElementById('btn-collapsed-project')?.addEventListener('click', () => {
      if (document.body.classList.contains('sidebar-collapsed')) toggle?.click();
      document.getElementById('project-selector')?.focus();
    });
  });
  window.VelaContent = Object.freeze({markdown, code, file, tool, icon, workflowKind});
})();
