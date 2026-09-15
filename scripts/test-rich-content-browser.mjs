#!/usr/bin/env node
/* Real browser security regression for the local, bounded content renderer. */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawn, execFileSync } from 'node:child_process';
import { resolve, relative, sep } from 'node:path';
import playwright from '../.task-tmp/ui-browser-tools/node_modules/playwright/index.js';
const { chromium } = playwright;

const ROOT = resolve(new URL('..', import.meta.url).pathname);
const uiFiles = JSON.parse(execFileSync('python3', ['-c', "import sys,json;sys.path.insert(0,'scripts');from release_resources import UI_RESOURCES;print(json.dumps(UI_RESOURCES))"], {cwd: ROOT, encoding: 'utf8'}));
const sha = path => createHash('sha256').update(readFileSync(path)).digest('hex');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function owned(path, root) { return path === root || path.startsWith(root + sep); }
function now() { return new Date().toISOString(); }

const args = process.argv.slice(2);
function option(name, required = true) {
  const index = args.indexOf(name);
  if (index < 0) { if (required) throw new Error(`Missing ${name}`); return null; }
  if (!args[index + 1]) throw new Error(`Missing value for ${name}`);
  return resolve(args[index + 1]);
}
const fixture = option('--fixture');
const output = option('--output');
const browserExecutable = option('--browser-executable');
const fixtureRoot = resolve(ROOT, '.task-tmp');
const outputRoot = resolve(ROOT, 'output', 'playwright');
if (!owned(fixture, fixtureRoot) || !owned(output, outputRoot) || existsSync(output)) throw new Error('Use an owned fixture and a NEW output/playwright directory.');
if (!existsSync(browserExecutable)) throw new Error('Browser executable does not exist.');
for (const path of [resolve(fixture, 'fixture.json'), resolve(fixture, 'vela-frozen'), resolve(fixture, 'ui-snapshot', 'content.js')]) {
  if (!existsSync(path)) throw new Error(`Missing frozen fixture input: ${path}`);
}

mkdirSync(output, { recursive: true });
const evidence = {
  format: 'vela-rich-content-browser-v1', synthetic: true, startedAt: now(),
  fixture, sourceBefore: Object.fromEntries(uiFiles.map(name => [name, sha(resolve(fixture, 'ui-snapshot', name))])),
  helperSHA256: sha(resolve(fixture, 'vela-frozen')), checks: [], pageErrors: [], consoleErrors: [], blockedResponses: [], unexpectedBlockedResponses: [], completeSuite: false,
};
let server, browser;
function record(name, ok, details = {}) { evidence.checks.push({ name, passed: ok, ...details }); }
async function check(name, callback, page) {
  try { await callback(); record(name, true); }
  catch (error) {
    record(name, false, { error: String(error), stack: error?.stack });
    await page.screenshot({ path: resolve(output, `failure-${name}.png`), fullPage: true }).catch(() => {});
  }
  writeFileSync(resolve(output, 'results.json'), JSON.stringify(evidence, null, 2) + '\n');
}
function writeFinal() {
  evidence.finishedAt = now();
  evidence.sourceAfter = Object.fromEntries(uiFiles.map(name => [name, sha(resolve(fixture, 'ui-snapshot', name))]));
  evidence.sourceUnchanged = JSON.stringify(evidence.sourceBefore) === JSON.stringify(evidence.sourceAfter);
  evidence.unexpectedBlockedResponses = evidence.blockedResponses.filter(row => !row.url.endsWith('/favicon.ico'));
  evidence.completeSuite = evidence.checks.length === 6 && evidence.checks.every(row => row.passed) && evidence.sourceUnchanged && evidence.pageErrors.length === 0 && evidence.unexpectedBlockedResponses.length === 0;
  writeFileSync(resolve(output, 'results.json'), JSON.stringify(evidence, null, 2) + '\n');
}

try {
  server = spawn('python3', [resolve(ROOT, 'scripts/test-ui-server.py'), resolve(fixture, 'fixture.json'), '--binary', resolve(fixture, 'vela-frozen'), '--ui-directory', resolve(fixture, 'ui-snapshot')], { cwd: ROOT, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '', stderr = '';
  server.stdout.setEncoding('utf8'); server.stderr.setEncoding('utf8');
  server.stdout.on('data', data => { stdout += data; }); server.stderr.on('data', data => { stderr += data; });
  const deadline = Date.now() + 15000;
  while (!stdout.includes('\n') && Date.now() < deadline && server.exitCode === null) await sleep(25);
  assert.ok(stdout.includes('\n'), `Fixture server did not start: ${stderr || stdout}`);
  const url = JSON.parse(stdout.slice(0, stdout.indexOf('\n'))).url;
  evidence.serverURL = url;
  browser = await chromium.launch({ headless: true, executablePath: browserExecutable });
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });
  await context.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: url });
  const page = await context.newPage();
  const requests = [];
  page.on('pageerror', error => evidence.pageErrors.push(String(error)));
  page.on('console', message => { if (message.type() === 'error') evidence.consoleErrors.push(message.text()); });
  page.on('request', request => requests.push(request.url()));
  page.on('response', response => { if (response.status() >= 400) evidence.blockedResponses.push({ url: response.url(), status: response.status() }); });
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('#session-search-input');

  await check('markdown-headings-lists-and-bounded-highlight', async () => {
    const result = await page.evaluate(() => {
      const host = document.createElement('div');
      host.id = 'rich-test-markdown';
      host.innerHTML = VelaContent.markdown('# Heading\n\n- first\n- second\n\n```js\nconst value = 7;\n```');
      document.body.append(host);
      return { heading: host.querySelector('h1')?.textContent, list: [...host.querySelectorAll('li')].map(x => x.textContent), code: host.querySelector('code')?.textContent, highlighted: !!host.querySelector('.token.keyword') };
    });
    assert.deepEqual(result, { heading: 'Heading', list: ['first', 'second'], code: 'const value = 7;', highlighted: true });
  }, page);

  await check('untrusted-html-url-svg-and-selector-injection-remain-inert', async () => {
    const beforeRequests = requests.length;
    const result = await page.evaluate(() => {
      window.__richContentPwned = 0;
      const token = 'rich-injected-control-91f5';
      const source = `<img src=x onerror="window.__richContentPwned=1"><a href="javascript:window.__richContentPwned=2">bad</a><svg onload="window.__richContentPwned=3"><circle></circle></svg><button id="${token}" class="btn-approve-ask" onclick="window.__richContentPwned=4">approve</button><span id="${token}-span" class="${token}" onclick="window.__richContentPwned=5">x</span>`;
      const host = document.createElement('div'); host.id = 'rich-test-untrusted'; host.innerHTML = VelaContent.markdown(source); document.body.append(host);
      return { pwned: window.__richContentPwned, activeNodes: [...host.querySelectorAll('img,a,svg,button,#'+token,'#'+token+'-span,.'+token)].length, eventAttrs: [...host.querySelectorAll('*')].flatMap(node => [...node.attributes].filter(attr => /^on/i.test(attr.name)).map(attr => attr.name)), literal: host.textContent };
    });
    assert.equal(result.pwned, 0);
    assert.equal(result.activeNodes, 0);
    assert.deepEqual(result.eventAttrs, []);
    assert.match(result.literal, /javascript:window/);
    const injectedRequests = requests.slice(beforeRequests);
    assert.equal(injectedRequests.some(url => /(?:^|\/)x(?:$|[?#])|javascript:/i.test(url)), false, `untrusted markup requested ${injectedRequests.join(', ')}`);
  }, page);

  await check('copy-preserves-first-last-newlines-and-crlf-exactly', async () => {
    const source = '\nfirst\r\n第二行\n\r\nlast\r\n';
    const result = await page.evaluate(async source => {
      const host = document.createElement('div'); host.id = 'rich-test-copy'; host.innerHTML = VelaContent.file(source, 'notes.md'); document.body.append(host);
      const encoded = host.querySelector('.reading-original').getAttribute('data-source');
      host.querySelector('.reading-copy').click();
      await new Promise(resolve => setTimeout(resolve, 100));
      return { encodedRoundTrip: JSON.parse(encoded), copied: await navigator.clipboard.readText(), view: host.querySelector('.reading-file').dataset.view };
    }, source);
    assert.equal(result.encodedRoundTrip, source);
    assert.equal(result.copied, source);
    assert.equal(result.view, 'preview');
  }, page);

  await check('large-and-long-lines-fall-back-within-bound', async () => {
    const result = await page.evaluate(() => {
      const over64k = '# title\n' + 'x'.repeat(64001);
      const overLine = '# title\n' + 'y'.repeat(8001);
      const start = performance.now();
      const a = VelaContent.markdown(over64k); const b = VelaContent.markdown(overLine);
      const elapsed = performance.now() - start;
      const hostA = document.createElement('div'); hostA.innerHTML=a;
      const hostB = document.createElement('div'); hostB.innerHTML=b;
      return { elapsed, aExact: hostA.querySelector('code')?.textContent === over64k, bExact: hostB.querySelector('code')?.textContent === overLine, headings: hostA.querySelectorAll('h1').length + hostB.querySelectorAll('h1').length };
    });
    assert.ok(result.elapsed < 1500, `bounded fallback took ${result.elapsed}ms`);
    assert.equal(result.aExact, true); assert.equal(result.bExact, true); assert.equal(result.headings, 0);
  }, page);

  await check('preview-source-toggle-uses-original-source-view', async () => {
    const result = await page.evaluate(() => {
      const host = document.createElement('div'); host.id='rich-test-toggle'; host.innerHTML=VelaContent.file('# Preview title\n\nBody', 'guide.md'); document.body.append(host);
      host.querySelector('.reading-source').click();
      const source = { view: host.querySelector('.reading-file').dataset.view, sourceVisible: getComputedStyle(host.querySelector('.reading-file-source')).display !== 'none', previewVisible: getComputedStyle(host.querySelector('.reading-file-preview')).display !== 'none', pressed: host.querySelector('.reading-source').getAttribute('aria-pressed') };
      host.querySelector('.reading-preview').click();
      return { source, preview: { view: host.querySelector('.reading-file').dataset.view, previewVisible: getComputedStyle(host.querySelector('.reading-file-preview')).display !== 'none', heading: host.querySelector('h1')?.textContent, pressed: host.querySelector('.reading-preview').getAttribute('aria-pressed') } };
    });
    assert.deepEqual(result.source, { view:'source', sourceVisible:true, previewVisible:false, pressed:'true' });
    assert.deepEqual(result.preview, { view:'preview', previewVisible:true, heading:'Preview title', pressed:'true' });
  }, page);

  await check('dynamic-locale-updates-view-controls', async () => {
    const result = await page.evaluate(() => {
      const host = document.createElement('div'); host.id='rich-test-locale'; host.innerHTML=VelaContent.file('# locale', 'locale.md'); document.body.append(host);
      VelaI18n.setLocale('en');
      const english = [...host.querySelectorAll('.reading-preview,.reading-source,.reading-copy')].map(x => x.textContent.trim());
      VelaI18n.setLocale('zh-CN');
      const chinese = [...host.querySelectorAll('.reading-preview,.reading-source,.reading-copy')].map(x => x.textContent.trim());
      return { english, chinese, lang: document.documentElement.lang };
    });
    assert.deepEqual(result.english, ['Preview','Source','Copy']);
    assert.notDeepEqual(result.chinese, result.english);
    assert.equal(result.lang, 'zh-CN');
  }, page);

  await page.screenshot({ path: resolve(output, 'rich-content-happy.png'), fullPage: true });
  await browser.close(); browser = null;
  server.kill('SIGTERM'); await new Promise(resolve => server.once('exit', resolve)); server = null;
} catch (error) {
  evidence.fatalError = String(error); evidence.fatalStack = error?.stack;
} finally {
  if (browser) await browser.close().catch(() => {});
  if (server && server.exitCode === null) { server.kill('SIGTERM'); await new Promise(resolve => server.once('exit', resolve)); }
  writeFinal();
}
process.exit(evidence.completeSuite ? 0 : 1);
