#!/usr/bin/env node
/** Browser acceptance checks. Usage: node scripts/test-website-browser.mjs [--dist DIR] [--url URL] [--output DIR] */
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { extname, join, relative, resolve, sep } from 'node:path';

const root = resolve(new URL('..', import.meta.url).pathname);
const defaults = { dist: join(root, '.task-tmp/website-bilingual-draft/dist'), output: join(root, 'output/playwright/website-bilingual-r1') };
const argv = process.argv.slice(2), values = {}, visualOnly = argv.includes('--visual-only');
for (let i = 0; i < argv.length;) { if (argv[i] === '--visual-only') { i += 1; continue; } if (!['--dist', '--url', '--output', '--browser-executable'].includes(argv[i]) || !argv[i + 1] || argv[i + 1].startsWith('--')) throw new Error('Usage: node scripts/test-website-browser.mjs [--dist DIR] [--url URL] [--output DIR] [--browser-executable PATH] [--visual-only]'); values[argv[i]] = argv[i + 1]; i += 2; }
const dist = resolve(values['--dist'] || defaults.dist), outputBase = resolve(values['--output'] || defaults.output);
const output = join(outputBase, `run-${new Date().toISOString().replace(/[:.]/g, '-')}`), requestedUrl = values['--url'];
const require = createRequire(import.meta.url), { chromium } = require(join(root, '.task-tmp/ui-browser-tools/node_modules/playwright'));
const systemChrome = values['--browser-executable'] || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
let executablePath; try { await stat(systemChrome); executablePath = systemChrome; } catch {}
const result = { generatedAt: new Date().toISOString(), dist, baseUrl: requestedUrl || null, output, sourceHash: {}, pages: [], failures: [], warnings: [] };
const fail = (kind, detail, path = null) => result.failures.push({ kind, detail, path });
const urlPath = (file) => { const p = relative(dist, file).split(sep).join('/'); return '/' + (p === 'index.html' ? '' : p.endsWith('/index.html') ? p.slice(0, -'index.html'.length) : p); };
const partner = (path) => path.startsWith('/en/') ? path.slice(3) || '/' : '/en' + path;
const localUrl = (href, base) => { try { const u = new URL(href, base); return u.origin === new URL(base).origin ? u : null; } catch { return null; } };
async function walk(dir) { const entries = await readdir(dir, { withFileTypes: true }); return (await Promise.all(entries.map((e) => e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]))).flat(); }
async function digestDirectory() { const files = (await walk(dist)).sort(), hash = createHash('sha256'); for (const file of files) { hash.update(relative(dist, file).split(sep).join('/')); hash.update('\0'); hash.update(await readFile(file)); hash.update('\0'); } return { algorithm: 'sha256', value: hash.digest('hex'), files: files.length, list: files }; }
function startServer(directory) { const mime = { '.css': 'text/css', '.js': 'text/javascript', '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.html': 'text/html' }; const server = createServer(async (req, res) => { try { let pathname = decodeURIComponent(new URL(req.url, 'http://127.0.0.1').pathname); if (pathname.endsWith('/')) pathname += 'index.html'; const file = resolve(directory, '.' + pathname); if (!file.startsWith(directory + sep) || (await stat(file)).isDirectory()) throw new Error('not found'); res.writeHead(200, { 'content-type': mime[extname(file)] || 'application/octet-stream' }); res.end(await readFile(file)); } catch { res.writeHead(404); res.end('Not found'); } }); return new Promise((done) => server.listen(0, '127.0.0.1', () => done({ server, url: `http://127.0.0.1:${server.address().port}` }))); }

let server; let browser; let context;
try {
  await mkdir(outputBase, { recursive: true }); await mkdir(output, { recursive: false }); result.sourceHash.before = await digestDirectory();
  const files = result.sourceHash.before.list.filter((file) => file.endsWith('.html'));
  if (files.length !== 32) fail('page-count', `Expected 32 HTML pages, found ${files.length}`);
  for (const file of files) if (/\b(?:Blume|Walrus|MemWal|px0)\b/i.test(await readFile(file, 'utf8'))) fail('prohibited-comparison-brand', 'Found a prohibited comparison brand in source.', urlPath(file));
  let baseUrl = requestedUrl; if (!baseUrl) { server = await startServer(dist); baseUrl = server.url; } result.baseUrl = baseUrl.replace(/\/$/, '');
  browser = await chromium.launch({ headless: true, ...(executablePath ? { executablePath } : {}) }); context = await browser.newContext(); await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: result.baseUrl });
  const page = await context.newPage(), probe = await context.newPage(), consoleProblems = [], missingResponses = new Map();
  for (const p of [page, probe]) { p.on('console', (m) => { if (m.type() === 'error') consoleProblems.push(`${p.url()}: ${m.text()}`); }); p.on('pageerror', (e) => consoleProblems.push(`${p.url()}: ${e.message}`)); p.on('response', (r) => { try { if (new URL(r.url()).origin === new URL(result.baseUrl).origin && r.status() >= 400) missingResponses.set(r.url(), r.status()); } catch {} }); }
  result.catalogueFilters = [];
  for (const prefix of ['', '/en']) {
    await page.setViewportSize({width:1440,height:900}); await page.goto(result.baseUrl+prefix+'/usecases/', {waitUntil:'networkidle'});
    const total=await page.locator('.usecases-table tbody tr[data-category]').count();
    if(total!==8) fail('catalogue-count', `Expected eight scenarios, got ${total}`, prefix+'/usecases/');
    for (const category of ['sessions','memory','workflows','lab','all']) {
      await page.locator(`.catalogue-pill[data-filter="${category}"]`).click();
      const visible=await page.locator('.usecases-table tbody tr[data-category]:visible').count(), expected=category==='all'?8:2;
      const status=await page.locator('#filter-status').innerText();
      result.catalogueFilters.push({path:prefix+'/usecases/',category,total,visible,expected,status});
      if(visible!==expected || !new RegExp(`${expected} (?:of|/) ${total}`).test(status)) fail('catalogue-filter', `${category}: ${visible} visible; ${status}`, prefix+'/usecases/');
      if(await page.locator(`.catalogue-pill[data-filter="${category}"]`).getAttribute('aria-pressed')!=='true') fail('catalogue-filter-aria',category,prefix+'/usecases/');
    }
  }
  if (visualOnly) {
    result.visualOnly = true; result.visual = [];
    for (const locale of ['zh', 'en']) for (const kind of ['home', 'comparisons', 'docs']) for (const width of [375, 1440]) {
      const path = (locale === 'en' ? '/en' : '') + ({ home: '/', comparisons: '/comparisons/', docs: '/docs.html' }[kind]);
      await page.setViewportSize({ width, height: 900 }); const response = await page.goto(result.baseUrl + path, { waitUntil: 'networkidle' });
      await page.addStyleTag({ content: 'html, body { scroll-behavior: auto !important; }' });
      const theme = await page.locator('html').getAttribute('data-theme'); if (theme !== 'light') fail('default-theme', `Fresh context expected light, got ${theme}`, path);
      const images = await page.evaluate(async () => { const images = [...document.images]; for (const image of images) { image.scrollIntoView({ block: 'center', behavior: 'instant' }); await new Promise((resolveImage) => { const until = Date.now() + 5000; const tick = () => image.complete && image.naturalWidth > 0 ? resolveImage() : Date.now() > until ? resolveImage() : setTimeout(tick, 50); tick(); }); } window.scrollTo({ top: 0, left: 0, behavior: 'instant' }); return images.map((image) => ({ src: image.currentSrc || image.src, complete: image.complete, naturalWidth: image.naturalWidth })); });
      for (const image of images) if (!image.complete || image.naturalWidth === 0) fail('lazy-image', `${image.src} did not load after scrollIntoView.`, path);
      await page.waitForFunction(() => window.scrollY === 0 && (() => { const header = document.querySelector('.site-header'); if (!header) return false; const box = header.getBoundingClientRect(); return box.top >= 0 && box.top <= 1 && box.height > 0; })());
      result.visual.push({ path, width, status: response?.status() ?? null, theme, images });
      if (kind === 'home' || kind === 'comparisons') await page.screenshot({ path: join(output, `${locale}-${kind}-${width}-top.png`) });
      await page.screenshot({ path: join(output, `${locale}-${kind}-${width}.png`), fullPage: true });
    }
  for (const [url, status] of missingResponses) fail('missing-local-resource', `${url} → ${status}`);
    if (consoleProblems.length) for (const message of consoleProblems) fail('browser-console', message);
  } else {
  for (const file of files) {
    const path = urlPath(file), expectedUrl = result.baseUrl + path, response = await page.goto(expectedUrl, { waitUntil: 'networkidle' });
    const row = { path, status: response?.status() ?? null, overflow: {}, language: null }; result.pages.push(row); if (row.status !== 200) fail('http-status', `Expected 200, received ${row.status}`, path);
    const pageUrl = page.url(), links = await page.evaluate(() => [...document.querySelectorAll('a[href], link[href], img[src], script[src]')].map((e) => ({ tag: e.tagName, href: e.getAttribute(e.hasAttribute('href') ? 'href' : 'src'), language: Boolean(e.closest('.header-lang-link, .lang-switch-link, [hreflang]')) })).filter((x) => x.href));
    for (const link of links) { const target = localUrl(link.href, pageUrl); if (!target) continue; if (path.startsWith('/en/') && link.tag === 'A' && !link.language && !target.pathname.startsWith('/en/')) fail('english-navigation-language', `${link.href} resolves outside /en/.`, path); const targetResponse = await page.request.get(target.href.split('#')[0]); if (targetResponse.status() >= 400) { fail('missing-local-link-or-resource', `${link.href} → ${targetResponse.status()}`, path); continue; } if (target.hash) { await probe.goto(target.href, { waitUntil: 'networkidle' }); if (!await probe.evaluate((id) => Boolean(document.getElementById(id)), decodeURIComponent(target.hash.slice(1)))) fail('missing-anchor', `${link.href} → ${target.hash}`, path); } }
    for (const width of [375, 768, 1440]) { await page.setViewportSize({ width, height: 900 }); row.overflow[width] = await page.evaluate(() => ({ scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth })); if (row.overflow[width].scrollWidth > row.overflow[width].clientWidth + 1) fail('horizontal-overflow', `${width}px: ${row.overflow[width].scrollWidth}px > ${row.overflow[width].clientWidth}px`, path); }
    await page.goto(expectedUrl, { waitUntil: 'networkidle' }); const language = page.locator('.header-lang-link').first();
    if (!await language.count()) fail('language-switch', 'Missing .header-lang-link.', path); else { await language.click(); await page.waitForLoadState('networkidle'); row.language = new URL(page.url()).pathname; if (row.language !== partner(path)) fail('language-path', `Expected ${partner(path)}, opened ${row.language}`, path); const expectedLang = path.startsWith('/en/') ? 'zh' : 'en'; if (!(await page.locator('html').getAttribute('lang'))?.toLowerCase().startsWith(expectedLang)) fail('language-document-lang', `Expected html[lang^=${expectedLang}].`, path); await page.goto(expectedUrl, { waitUntil: 'networkidle' }); }
    if (path.startsWith('/en/')) { const leaks = await page.evaluate(() => { const excluded = (e) => e.closest('[lang^="zh" i], .header-lang-link, .lang-switch-link'); const text = [...document.body.querySelectorAll('*')].filter((e) => !e.children.length && !excluded(e)).map((e) => e.textContent || '').filter((t) => /[\u3400-\u9fff]/.test(t)); const attrs = [...document.querySelectorAll('[aria-label], [title], img[alt]')].filter((e) => !excluded(e)).flatMap((e) => ['aria-label', 'title', 'alt'].map((a) => e.getAttribute(a) || '')).filter((v) => /[\u3400-\u9fff]/.test(v)); return [...new Set([...text, ...attrs])].slice(0, 8); }); if (leaks.length) fail('english-content-chinese', leaks.join(' | '), path); }
  }
  for (const [url, status] of missingResponses) fail('missing-local-resource', `${url} → ${status}`);
  await page.setViewportSize({ width: 375, height: 900 }); await page.goto(result.baseUrl + '/', { waitUntil: 'networkidle' }); const menu = page.locator('.mobile-menu-toggle');
  if (!await menu.count()) fail('mobile-nav', 'Missing .mobile-menu-toggle.', '/'); else { await menu.click(); if (await menu.getAttribute('aria-expanded') !== 'true') fail('mobile-nav', 'Menu did not open.', '/'); if (!await page.evaluate(() => document.getElementById('mobile-nav-panel')?.contains(document.activeElement))) fail('mobile-nav-focus', 'Opening menu did not focus its first link.', '/'); await page.keyboard.press('Escape'); if (await menu.getAttribute('aria-expanded') !== 'false') fail('mobile-nav-escape', 'Escape did not close menu.', '/'); if (!await page.evaluate(() => document.activeElement?.classList.contains('mobile-menu-toggle'))) fail('mobile-nav-focus', 'Escape did not restore focus.', '/'); }
  const theme = page.locator('.theme-toggle-btn').first(); if (!await theme.count()) fail('theme', 'Missing .theme-toggle-btn', '/'); else { await theme.click(); const selected = await page.locator('html').getAttribute('data-theme'); await menu.click(); await page.locator('#mobile-nav-panel a[href="/docs.html"]').click(); await page.waitForLoadState('networkidle'); if (await page.locator('html').getAttribute('data-theme') !== selected) fail('theme-persistence', 'Theme changed after internal navigation.', '/docs.html'); }
  const toc = page.locator('.docs-toc-toggle').first(); if (await toc.count()) { await toc.click(); if (await toc.getAttribute('aria-expanded') !== 'true') fail('docs-toc', 'Docs TOC did not open.', '/docs.html'); }
  await page.goto(result.baseUrl + '/', { waitUntil: 'networkidle' }); const copy = page.locator('[data-copy-text], [data-copy-target]').first(); if (!await copy.count()) fail('copy-control', 'No copy control found.', '/'); else { const expected = await copy.evaluate((el) => { const direct = el.getAttribute('data-copy-text'), selector = el.getAttribute('data-copy-target'); return direct || (selector ? document.querySelector(selector)?.textContent?.trim() : ''); }); await copy.click(); if ((await page.evaluate(() => navigator.clipboard.readText())) !== expected) fail('clipboard', 'Clipboard text does not match copy source.', '/'); }
  for (const locale of ['zh', 'en']) for (const kind of ['home', 'comparisons', 'docs']) for (const width of [375, 1440]) { const path = (locale === 'en' ? '/en' : '') + ({ home: '/', comparisons: '/comparisons/', docs: '/docs.html' }[kind]); await page.setViewportSize({ width, height: 900 }); await page.goto(result.baseUrl + path, { waitUntil: 'networkidle' }); await page.screenshot({ path: join(output, `${locale}-${kind}-${width}.png`), fullPage: true }); }
  if (consoleProblems.length) for (const message of consoleProblems) fail('browser-console', message);
  }
} catch (error) { fail('harness-error', error?.stack || String(error)); }
finally { if (context) await context.close(); if (browser) await browser.close(); if (server) await new Promise((done) => server.server.close(done)); try { result.sourceHash.after = await digestDirectory(); result.sourceHash.unchanged = result.sourceHash.before?.value === result.sourceHash.after.value; if (!result.sourceHash.unchanged) fail('source-changed-during-run', 'dist changed while browser evidence was collected.'); } catch (error) { fail('post-run-hash', String(error)); } await writeFile(join(output, 'report.json'), JSON.stringify(result, null, 2) + '\n'); }
console.log(JSON.stringify({ sourceHash: result.sourceHash, pages: result.pages.length, failures: result.failures.length, warnings: result.warnings.length, report: join(output, 'report.json') }, null, 2)); process.exitCode = result.failures.length ? 1 : 0;
