/* Local, bounded rich content. All provider/project text is untrusted. */
(function () {
  'use strict';
  window.Prism = window.Prism || {};
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const label = key => window.VelaI18n ? window.VelaI18n.t('reading.' + key) : key;
  const textLabel = key => `<span data-i18n="reading.${key}">${escape(label(key))}</span>`;
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
    return `<section class="reading-file" data-view="${isMarkdown ? 'preview' : 'source'}">
      <div class="reading-file-toolbar">
        <span class="reading-file-name">${escape(String(filename).split('/').pop() || label('content'))}</span>
        ${isMarkdown ? `<button type="button" class="btn btn-sm btn-ghost reading-preview" aria-pressed="true">${textLabel('preview')}</button><button type="button" class="btn btn-sm btn-ghost reading-source" aria-pressed="false">${textLabel('source')}</button>` : ''}
        <button type="button" class="btn btn-sm btn-ghost reading-copy">${textLabel('copy')}</button>
      </div>
      ${isMarkdown ? `<div class="reading-file-preview">${markdown(text)}</div>` : ''}
      <div class="reading-file-source">${code(text, ext)}</div>
      <span class="reading-original" hidden data-source="${escape(JSON.stringify(text))}"></span>
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
  // Native details provides keyboard disclosure; close action menus after selection/outside/Escape.
  document.addEventListener('click', event => {
    document.querySelectorAll('details.action-menu[open]').forEach(menu => {
      if (!menu.contains(event.target) || event.target.closest('button')) menu.open = false;
    });
  });
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    document.querySelectorAll('details.action-menu[open]').forEach(menu => {menu.open=false; menu.querySelector('summary').focus();});
  });
  window.VelaContent = Object.freeze({markdown, code, file});
})();
