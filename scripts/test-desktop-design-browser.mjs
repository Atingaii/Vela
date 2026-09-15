#!/usr/bin/env node
/**
 * Design acceptance for a *frozen* Vela renderer served by an already-created
 * isolated fixture.  This runner deliberately has no fixture creation or
 * provider code: its --fixture-contract names records created beforehand by
 * real CLI/RPC setup, so DOM injection can never manufacture a passing case.
 *
 * Usage:
 *   node scripts/test-desktop-design-browser.mjs \
 *     --url http://127.0.0.1:PORT/ --fixture-contract fixture-contract.json \
 *     --output output/playwright/design/results.json --screenshots output/.../shots \
 *     [--browser '/Applications/Google Chrome.app/...']
 *
 * The fixture contract is JSON and must contain actual persisted records:
 * {
 *   "workflowLongChinese": {"id":"…","title":"…","description":"…"},
 *   "workflowLongEnglish": {"id":"…","title":"…","description":"…"},
 *   "allProjectsWorkflow": {"id":"…","project":"…","title":"…"},
 *   "approval": {"id":"…","sourceText":"exact full source"},
 *   "toolCommand": {"sessionId":"…","command":"…","rawRecord":"…"},
 *   "workflowIcons": {"gitIDs":["…","…"],"writeID":"…"}
 * }
 * Setup must create/save these through the real helper before the browser is
 * opened.  This script only reads them through the rendered product.
 */
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('../.task-tmp/ui-browser-tools/node_modules/playwright');

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const PAGES = ['agents', 'workflows', 'memory', 'setup', 'inbox', 'usage', 'improve', 'lab', 'settings'];
const NARROW_PAGES = ['agents', 'setup', 'usage', 'improve'];
const IMPORTANT_SCREENSHOTS = new Set(PAGES);
const arg = (name) => {
  const index = process.argv.indexOf(name);
  return index < 0 ? null : process.argv[index + 1];
};
const has = (name) => process.argv.includes(name);

if (has('--help')) {
  console.log('Usage: node scripts/test-desktop-design-browser.mjs --url LOCAL_FIXTURE_URL --fixture-contract FILE --output FILE --screenshots DIR [--browser CHROME]');
  process.exit(0);
}
const url = arg('--url');
const contractPath = arg('--fixture-contract');
const outputPath = arg('--output');
const screenshotsDir = arg('--screenshots');
const browserPath = arg('--browser');
if (!url || !contractPath || !outputPath || !screenshotsDir) throw new Error('required: --url --fixture-contract --output --screenshots');
if (!/^http:\/\/(127\.0\.0\.1|localhost)(?::\d+)?\/[^?#]*\/$/.test(url)) throw new Error('--url must be an explicit local fixture URL ending in /.');
if (!fs.statSync(contractPath).isFile() || fs.lstatSync(contractPath).isSymbolicLink()) throw new Error('--fixture-contract must be an ordinary JSON file.');
const contract = JSON.parse(fs.readFileSync(contractPath, 'utf8'));
for (const name of ['workflowLongChinese', 'workflowLongEnglish', 'allProjectsWorkflow', 'approval', 'toolCommand', 'workflowIcons']) {
  if (!contract[name] || typeof contract[name] !== 'object') throw new Error(`fixture contract is missing ${name}; create it through real helper/RPC setup.`);
}
fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.mkdirSync(screenshotsDir, { recursive: true });
const fixtureDir = path.dirname(contractPath);
const frozenUIPath = path.join(fixtureDir, 'ui-snapshot');
if (!fs.statSync(frozenUIPath).isDirectory() || fs.lstatSync(frozenUIPath).isSymbolicLink()) throw new Error('fixture must retain an ordinary ui-snapshot directory.');
const UI_SOURCE_FILES = ['app.js', 'appearance.js', 'app.css', 'content.js', 'reading.css', 'i18n.js', 'index.html'];
const treeHashes = (dir) => {
  const names = fs.readdirSync(dir).sort().filter(name => fs.lstatSync(path.join(dir, name)).isFile() && !fs.lstatSync(path.join(dir, name)).isSymbolicLink());
  for (const name of UI_SOURCE_FILES) {
    if (!names.includes(name)) throw new Error(`frozen UI snapshot is missing required source ${name}.`);
  }
  return Object.fromEntries(names.map(name => [name, createHash('sha256').update(fs.readFileSync(path.join(dir, name))).digest('hex')]));
};
const setupPath = path.join(fixtureDir, 'design-fixture-setup.json');
const setup = fs.existsSync(setupPath) ? JSON.parse(fs.readFileSync(setupPath, 'utf8')) : null;
const uiSourceBefore = treeHashes(frozenUIPath);
const helperPath = typeof setup?.helperPath === 'string' && fs.existsSync(setup.helperPath) && !fs.lstatSync(setup.helperPath).isSymbolicLink() ? setup.helperPath : null;
const helperBefore = helperPath ? createHash('sha256').update(fs.readFileSync(helperPath)).digest('hex') : setup?.helperSHA256 || null;

const report = {
  format: 'vela-desktop-design-browser-v2',
  syntheticFixture: true,
  fixtureURL: url,
  fixtureContractSHA256: await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(contract))).then(bytes => Buffer.from(bytes).toString('hex')),
  providerExecuted: false,
  workflowToolExecuted: false,
  completeSpecification: false,
  servedUISourceSHA256: uiSourceBefore,
  helperSHA256Before: helperBefore,
  checks: [],
  pageObservations: {},
  screenshots: [],
  limitations: [
    'This is a frozen-renderer browser acceptance run. Native window chrome, system notification delivery, and external providers are out of scope.',
    'The fixture contract must be created by real helper/RPC setup; this runner never inserts or rewrites DOM data.',
  ],
};
const persist = () => fs.writeFileSync(outputPath, JSON.stringify(report, null, 2) + '\n');
const browser = await chromium.launch({ headless: true, ...(browserPath ? { executablePath: browserPath } : {}) });
const page = await browser.newPage({ viewport: { width: 1250, height: 800 } });
page.setDefaultTimeout(8_000);
const pageErrors = [];
const failedResources = [];
page.on('response', response => { if (response.status() >= 400) failedResources.push({ status: response.status(), url: response.url() }); });
page.on('pageerror', error => pageErrors.push(String(error)));
page.on('console', message => { if (message.type() === 'error') pageErrors.push({ message: message.text(), location: message.location() }); });

const screenshot = async (name) => {
  const file = path.join(screenshotsDir, `${name}.png`);
  await page.screenshot({ animations: 'disabled', path: file, fullPage: true });
  report.screenshots.push(path.relative(ROOT, file));
};
const locatorVisible = async (locator) => await locator.count() > 0 && await locator.first().isVisible();
// Both responsive navigation surfaces retain the same selected route. The
// interaction helper below only clicks the visible surface; reading that
// shared route must not require there to be only one DOM navigation control.
const activePage = () => page.locator('.nav-link.active[data-page], .companion-link.active[data-page]').first();
const pageReady = {
  agents: '#session-search-input', workflows: '#workflows-tab-content', memory: '#memory-page-content',
  setup: '#btn-scan-setup', inbox: '#approval-list, .empty-state', usage: '#usage-codex-quota-card',
  improve: '#page-container .page-header', lab: '#page-container .page-header', settings: '#setting-locale'
};
const visiblePageLink = async (name) => {
  const direct = page.locator(`.nav-link[data-page="${name}"]:visible, .companion-link[data-page="${name}"]:visible`).first();
  if (await locatorVisible(direct)) return direct;
  // Companion secondary routes are deliberately disclosed from the More menu;
  // never fall back to clicking an invisible desktop sidebar item.
  const more = page.locator('.companion-nav .action-menu > summary:visible').first();
  if (await locatorVisible(more)) {
    await more.click();
    const disclosed = page.locator(`.companion-link[data-page="${name}"]:visible`).first();
    if (await locatorVisible(disclosed)) return disclosed;
  }
  throw new Error(`visible page navigation missing: ${name}`);
};
const go = async (name) => {
  const link = await visiblePageLink(name);
  await link.click();
  await page.waitForFunction(pageName => document.querySelector('.nav-link.active[data-page], .companion-link.active[data-page]')?.dataset.page === pageName, name);
  const readiness = pageReady[name];
  if (readiness) await page.locator(readiness).first().waitFor({ state: 'visible', timeout: 8_000 });
  if (name === 'usage') await page.waitForFunction(() => {
    const accountTab = document.querySelector('[data-usagetab="quota"]');
    const accountPanel = document.querySelector('#usage-codex-quota-card:not([hidden])');
    return Boolean(accountTab && (accountTab.classList.contains('active') || accountTab.getAttribute('aria-selected') === 'true' || accountTab.getAttribute('aria-pressed') === 'true') && accountPanel?.querySelector('.quota-provider-heading') && !accountPanel.querySelector('[data-i18n="common.loading"]'));
  });
};
const isNoPageOverflow = () => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
const visibleRect = (selector) => page.evaluate((item) => {
  const el = document.querySelector(item);
  if (!el) return null;
  const rect = el.getBoundingClientRect();
  return { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height };
}, selector);
const record = async (name, action) => {
  const item = { check: name, passed: false };
  try {
    item.observation = await action();
    item.passed = true;
  } catch (error) {
    item.error = String(error);
    try { await screenshot(`failure-${name}`); } catch (captureError) { item.captureError = String(captureError); }
  }
  item.pageErrors = pageErrors.splice(0);
  item.failedResources = failedResources.splice(0);
  if ((item.pageErrors.length || item.failedResources.length) && item.passed) {
    item.passed = false;
    item.error = `browser console/page errors occurred during this check: ${item.pageErrors.map(error => JSON.stringify(error)).join(' | ')} ${JSON.stringify(item.failedResources)}`;
  }
  report.checks.push(item);
  persist();
  console.log(JSON.stringify(item));
};
const setLocale = async (locale) => {
  await go('settings');
  const select = page.locator('#setting-locale');
  await select.waitFor({ state: 'visible', timeout: 8_000 });
  await select.selectOption(locale);
  await page.waitForFunction(value => window.VelaI18n?.getLocale?.() === value && document.querySelector('#setting-locale')?.disabled === false, locale);
};
const requiredTitle = (value, label) => {
  if (!value || typeof value.id !== 'string' || !value.id || typeof value.title !== 'string' || !value.title || typeof value.description !== 'string') {
    throw new Error(`fixture contract ${label} requires id, nonempty title, and description from a real saved workflow.`);
  }
};
const workflowRow = (id) => page.locator(`.workflow-row[data-id="${id}"]`);

try {
  await page.goto(url, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.nav-link[data-page="agents"]');
  await page.evaluate(() => {
    if (window.__desktopDesignCalls || !window.vela?.call) return;
    const original = window.vela.call.bind(window.vela);
    window.__desktopDesignCalls = [];
    window.vela.call = async (method, params = {}) => {
      window.__desktopDesignCalls.push({ method, params: JSON.parse(JSON.stringify(params)) });
      return original(method, params);
    };
  });

  for (const locale of ['zh-CN', 'en']) {
    await record(`all-nine-pages-${locale}-1250x800`, async () => {
      await page.setViewportSize({ width: 1250, height: 800 });
      await setLocale(locale);
      const observations = [];
      for (const name of PAGES) {
        await go(name);
        const overflow = !(await isNoPageOverflow());
        const header = await page.locator('.page-header h1, .page-title-group h1, main h1').first().textContent().catch(() => null);
        observations.push({ page: name, active: await activePage().getAttribute('data-page'), header: header?.trim() || null, pageHorizontalOverflow: overflow });
        if (overflow) throw new Error(`${locale}/${name}: document has horizontal overflow at 1250×800.`);
        if (locale === 'zh-CN' && IMPORTANT_SCREENSHOTS.has(name)) await screenshot(`design-${name}-zh-1250x800`);
      }
      await go('settings');
      const aria = await page.evaluate(() => {
        const labels = [...document.querySelectorAll('.settings-nav, [data-settings-panel]')]
          .map(element => ({ role: element.classList.contains('settings-nav') ? 'navigation' : 'panel', label: element.getAttribute('aria-label') || '' }));
        return labels;
      });
      const readable = locale === 'zh-CN' ? /[\u3400-\u9fff]/ : /[A-Za-z]/;
      if (!aria.length || aria.some(item => !item.label || !readable.test(item.label))) throw new Error(`${locale}: settings navigation/panel aria-labels did not update to readable current-locale text.`);
      report.pageObservations[locale] = observations;
      return { viewport: [1250, 800], pages: observations, settingsAria: aria };
    });
  }

  await record('companion-core-pages-440x760', async () => {
    await page.setViewportSize({ width: 440, height: 760 });
    const observations = [];
    for (const name of NARROW_PAGES) {
      await go(name);
      const overflow = !(await isNoPageOverflow());
      observations.push({ page: name, pageHorizontalOverflow: overflow });
      if (overflow) throw new Error(`${name}: document has horizontal overflow at 440×760.`);
      await screenshot(`design-${name}-companion-440x760`);
    }
    return { viewport: [440, 760], pages: observations };
  });

  await record('activity-history-entry-and-account-default-use-visible-current-shell-controls', async () => {
    await page.setViewportSize({ width: 1250, height: 800 });
    await go('agents');
    const activity = page.locator('[data-agentstab="sessions"]:visible');
    const history = page.locator('[data-agentstab="recent"]:visible');
    if (!(await locatorVisible(activity)) || !(await locatorVisible(history))) throw new Error('Activity and History entry controls must remain visible in the desktop shell.');
    await activity.click();
    await page.waitForFunction(() => document.querySelector('[data-agentstab="sessions"]')?.classList.contains('active'));
    await history.click();
    await page.waitForFunction(() => document.querySelector('[data-agentstab="recent"]')?.classList.contains('active'));
    await go('usage');
    const account = page.locator('[data-usagetab="quota"]').first();
    const accountPanel = page.locator('#usage-codex-quota-card:not([hidden])').first();
    if (!(await locatorVisible(account)) || !(await locatorVisible(accountPanel))) throw new Error('Usage must open the visible Account tab and panel by default.');
    const accountSelected = await account.evaluate(element => element.classList.contains('active') || element.getAttribute('aria-selected') === 'true' || element.getAttribute('aria-pressed') === 'true');
    if (!accountSelected) throw new Error('Usage Account tab is rendered but not selected by default.');
    return { activityHistoryVisible: true, accountDefault: true };
  });

  await record('sidebar-collapse-removes-hidden-navigation-from-focus', async () => {
    await page.setViewportSize({ width: 1250, height: 800 });
    const projectSelector = page.locator('#project-selector');
    const scopedProject = contract.workflowLongChinese.project;
    if (!scopedProject || !(await locatorVisible(projectSelector))) throw new Error('fixture must expose the persisted workflow project before collapsed-scope verification.');
    await projectSelector.selectOption(scopedProject);
    await page.waitForFunction(project => document.querySelector('#project-selector')?.value === project, scopedProject);
    const trigger = page.locator('#btn-toggle-sidebar, .sidebar-collapse-btn, [data-action="toggle-sidebar"]').first();
    if (!(await locatorVisible(trigger))) throw new Error('missing visible sidebar collapse control.');
    await trigger.focus();
    await trigger.click();
    await page.waitForFunction(() => document.body.classList.contains('sidebar-collapsed') || document.querySelector('.sidebar')?.getAttribute('aria-hidden') === 'true');
    const hiddenFocusable = await page.evaluate(() => {
      const sidebar = document.querySelector('.sidebar');
      if (!sidebar) return { hidden: false, actualFocusable: [] };
      const style = getComputedStyle(sidebar);
      const candidates = [...sidebar.querySelectorAll('a,button,input,select,textarea,[tabindex]')];
      const actualFocusable = [];
      for (const element of candidates) {
        const prior = document.activeElement;
        element.focus();
        if (document.activeElement === element) actualFocusable.push(element.id || element.getAttribute('data-page') || element.tagName);
        prior?.focus?.();
      }
      return { hidden: style.display === 'none' || sidebar.getAttribute('aria-hidden') === 'true' || sidebar.inert === true, actualFocusable };
    });
    if (!hiddenFocusable.hidden || hiddenFocusable.actualFocusable.length) throw new Error(`collapsed sidebar retains keyboard focus: ${hiddenFocusable.actualFocusable.join(', ')}`);
    const collapsedScope = page.locator('#btn-collapsed-project');
    if (!(await locatorVisible(collapsedScope))) throw new Error('collapsed sidebar hides the active project scope control.');
    const scope = await collapsedScope.evaluate(element => ({ label: element.querySelector('.collapsed-project-name')?.textContent?.trim() || '', title: element.getAttribute('title') || '' }));
    if (!scope.label || !scope.title || scope.title !== scopedProject) throw new Error('collapsed scope control does not retain a visible selected-project label and canonical scope title.');
    await trigger.click();
    if (await projectSelector.inputValue() !== scopedProject) throw new Error('restoring sidebar lost the selected project scope.');
    return { ...hiddenFocusable, collapsedScope: scope, selectionRetained: true };
  });

  await record('workflow-agent-setup-lab-tabs-expose-single-pressed-selection', async () => {
    const groups = [
      { page: 'agents', selector: '[data-agentstab]' }, { page: 'workflows', selector: '[data-wftab]' },
      { page: 'setup', selector: '[data-setuptab]' }, { page: 'lab', selector: '[data-labtab]' },
    ];
    const observations = [];
    for (const group of groups) {
      await go(group.page);
      const buttons = page.locator(group.selector);
      const count = await buttons.count();
      if (count < 2) throw new Error(`${group.page} lacks multiple real selectable tabs.`);
      const statesBefore = await buttons.evaluateAll(elements => elements.map(element => element.getAttribute('aria-pressed')));
      if (statesBefore.filter(value => value === 'true').length !== 1 || statesBefore.some(value => value !== 'true' && value !== 'false')) throw new Error(`${group.page} tab aria-pressed does not expose exactly one selected state.`);
      await buttons.nth(1).click();
      const statesAfter = await buttons.evaluateAll(elements => elements.map(element => element.getAttribute('aria-pressed')));
      if (statesAfter.filter(value => value === 'true').length !== 1 || statesAfter[1] !== 'true') throw new Error(`${group.page} tab click did not update aria-pressed selection.`);
      // Keep each subsequent independent check on the product's default tab.
      // The restore itself is another real selection assertion, not a DOM edit.
      await buttons.nth(0).click();
      const statesRestored = await buttons.evaluateAll(elements => elements.map(element => element.getAttribute('aria-pressed')));
      if (statesRestored.filter(value => value === 'true').length !== 1 || statesRestored[0] !== 'true') throw new Error(`${group.page} default tab did not restore after aria state exercise.`);
      observations.push({ page: group.page, count, statesBefore, statesAfter, statesRestored });
    }
    return observations;
  });

  await record('actual-tool-command-is-exact-copyable-raw-and-html-inert', async () => {
    await go('agents');
    const fixture = contract.toolCommand;
    if (!fixture.sessionId || !fixture.title || !fixture.command || !fixture.rawRecord) throw new Error('toolCommand fixture contract lacks real source identity or exact bytes.');
    const session = page.locator(`.session-card[data-id="${fixture.sessionId}"]`);
    if (!(await locatorVisible(session))) {
      await page.locator('[data-agentstab="recent"]:visible').click();
      await page.waitForFunction(() => document.querySelector('[data-agentstab="recent"]')?.classList.contains('active'));
    }
    if (!(await locatorVisible(session))) throw new Error('real helper did not render the ingested tool-command session.');
    await session.locator('.session-title-btn').click();
    const drawer = page.locator('#detail-drawer:not(.hidden)');
    await drawer.waitFor({ state: 'visible' });
    const invocation = drawer.locator(`.tool-invocation[data-tool="${fixture.name}"]`);
    await invocation.waitFor({ state: 'visible', timeout: 8_000 });
    const commandSource = invocation.locator(':scope > .tool-primary-source code').first();
    if (await commandSource.textContent() !== fixture.command) throw new Error('rendered command differs from exact provider command bytes.');
    const copy = invocation.locator(':scope > .tool-invocation-heading .reading-copy').first();
    if (!(await locatorVisible(copy))) throw new Error('recorded command lacks a real copy control.');
    await page.context().grantPermissions(['clipboard-read', 'clipboard-write'], { origin: new URL(url).origin });
    await copy.click();
    const copied = await page.evaluate(() => navigator.clipboard.readText());
    if (copied !== fixture.command) throw new Error('actual copy handler did not write the exact recorded command.');
    const raw = invocation.locator('.tool-raw-record');
    await raw.locator('summary').click();
    const rawSource = raw.locator('.reading-file-source code').first();
    if (await rawSource.textContent() !== fixture.rawRecord) throw new Error('raw record disclosure differs from exact ingested provider bytes.');
    const result = await invocation.locator('.tool-observation-note').count();
    if (result !== 1 || await invocation.locator('.tool-output, .status-sage, [data-status="success"]').count() !== 0) throw new Error('missing tool output was rendered as a completed/successful result.');
    const inert = await invocation.evaluate(element => ({
      injected: element.querySelectorAll('img,script,[onerror]').length,
      global: Object.prototype.hasOwnProperty.call(window, '__vela_design_tool_xss'),
    }));
    if (inert.injected || inert.global) throw new Error('HTML-shaped command input created executable or element fallback rather than literal source text.');
    return { sessionId: fixture.sessionId, commandBytes: Buffer.byteLength(fixture.command), rawSourceExact: true, copiedExact: true, noOutputObserved: true, inert };
  });

  await record('workflow-icons-follow-real-trigger-and-step-class', async () => {
    await go('workflows');
    const fixture = contract.workflowIcons;
    if (!Array.isArray(fixture.gitIDs) || fixture.gitIDs.length !== 2 || !fixture.writeID) throw new Error('workflowIcons fixture contract must name real persisted git and write workflows.');
    const icon = async id => {
      const node = workflowRow(id).locator('.workspace-row-icon').first();
      if (!(await locatorVisible(node))) throw new Error(`real workflow ${id} is absent from list.`);
      return node.evaluate(element => ({ kind: element.getAttribute('data-kind'), svg: element.querySelector('svg')?.outerHTML || '' }));
    };
    const [firstGit, secondGit, write] = await Promise.all([...fixture.gitIDs.map(icon), icon(fixture.writeID)]);
    if (firstGit.kind !== 'branch' || secondGit.kind !== 'branch' || !firstGit.svg || firstGit.svg !== secondGit.svg) throw new Error('two real git-step workflows do not receive the same branch icon.');
    if (write.kind !== 'document' || !write.svg || write.svg === firstGit.svg) throw new Error('real file.write workflow did not receive a distinct document icon.');
    return { git: firstGit.kind, write: write.kind, sameGitIcon: true, distinctWriteIcon: true };
  });

  await record('saved-workflow-long-titles-and-menu', async () => {
    await go('workflows');
    requiredTitle(contract.workflowLongChinese, 'workflowLongChinese');
    requiredTitle(contract.workflowLongEnglish, 'workflowLongEnglish');
    await page.evaluate(() => {
      window.__menuTestEvents = [];
      for (const name of ['click', 'toggle', 'scroll', 'focusin']) document.addEventListener(name, event => {
        window.__menuTestEvents.push({type: name, target: event.target.tagName, className: String(event.target.className || ''), open: event.target.open, time: performance.now(), openMenus: document.querySelectorAll('details.action-menu[open]').length});
        if (window.__menuTestEvents.length > 40) window.__menuTestEvents.shift();
      }, true);
    });
    const inspected = [];
    for (const [label, fixture] of Object.entries({ chinese: contract.workflowLongChinese, english: contract.workflowLongEnglish })) {
      const row = workflowRow(fixture.id);
      if (!(await locatorVisible(row))) throw new Error(`${label} long-title workflow is not rendered; fixture setup must persist it through workflows.save.`);
      const title = row.locator('.row-title.btn-wf-inspect').first();
      const description = row.locator('.row-description').first();
      if (await title.textContent() !== fixture.title) throw new Error(`${label} rendered title differs from real saved workflow.`);
      const info = await title.evaluate((el) => {
        const style = getComputedStyle(el); const rect = el.getBoundingClientRect();
        return { title: el.getAttribute('title'), aria: el.getAttribute('aria-label') || el.textContent?.trim(), nowrap: style.whiteSpace, overflow: style.overflow, textOverflow: style.textOverflow, width: rect.width };
      });
      if (info.title !== fixture.title || info.aria !== fixture.title || info.nowrap !== 'nowrap' || info.overflow !== 'hidden' || info.textOverflow !== 'ellipsis') throw new Error(`${label} title must keep exact full tooltip/accessibility text and one-line ellipsis styling.`);
      if (!(await locatorVisible(description))) throw new Error(`${label} description is absent.`);
      const desc = await description.evaluate((el) => {
        const style = getComputedStyle(el); const h = el.getBoundingClientRect().height; const lh = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.25;
        return { rendered: el.textContent || '', lineClamp: style.webkitLineClamp, overflow: style.overflow, lineHeight: lh, height: h };
      });
      if (desc.rendered !== fixture.description) throw new Error(`${label} description differs from the real saved workflow.`);
      // Clamp is asserted in its own check so a styling failure cannot hide menu/focus evidence.
      inspected.push({ label, title: info, description: desc });
      const menuTrigger = row.locator('details.action-menu > summary, button[aria-haspopup="menu"]').first();
      if (!(await locatorVisible(menuTrigger))) throw new Error(`${label} workflow row has no named action menu trigger.`);
      const [titleBox, menuBox, rowBox] = await Promise.all([title.boundingBox(), menuTrigger.boundingBox(), row.boundingBox()]);
      if (!titleBox || !menuBox || !rowBox || menuBox.width < 36 || menuBox.height < 36 || titleBox.x + titleBox.width > menuBox.x || menuBox.x + menuBox.width > rowBox.x + rowBox.width + 0.5) throw new Error(`${label} title/menu geometry violates fixed reachable action menu.`);
      await menuTrigger.evaluate(element => element.scrollIntoView({ block: 'end', inline: 'nearest' }));
      // Scrolling intentionally closes an open product menu. Finish the setup
      // scroll (including its queued scroll event) before opening the menu.
      await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      await menuTrigger.focus();
      await menuTrigger.click();
      const menu = row.locator('details.action-menu').first();
      if (!(await menu.evaluate(el => el.open))) throw new Error(`${label} action menu did not open exactly once.`);
      const panel = menu.locator('.action-menu-items');
      await panel.waitFor({ state: 'visible' });
      // Native details toggles dispatch asynchronously; await the product's
      // positioning handler before measuring the actual popup.
      try {
        await page.waitForFunction(el => el.style.left && el.style.top && el.parentElement.querySelector('summary')?.getAttribute('aria-expanded') === 'true', await panel.elementHandle());
      } catch (error) {
        throw new Error(`${label} positioning did not settle: ${JSON.stringify(await page.evaluate(() => window.__menuTestEvents))}; ${error}`);
      }
      const menuRect = await panel.boundingBox();
      const viewport = page.viewportSize();
      if (!menuRect || !viewport || menuRect.x < 0 || menuRect.x + menuRect.width > viewport.width || menuRect.y < 0 || menuRect.y + menuRect.height > viewport.height) throw new Error(`${label} action menu is unreachable near the viewport edge: ${JSON.stringify(menuRect)} in ${JSON.stringify(viewport)}.`);
      const items = panel.locator('button:not(:disabled)');
      if (!(await items.count())) throw new Error(`${label} action menu has no available actions.`);
      await page.keyboard.press('ArrowDown');
      if (!(await items.first().evaluate(el => document.activeElement === el))) throw new Error(`${label} ArrowDown did not focus the first action.`);
      await items.first().click({ trial: true });
      await page.keyboard.press('End');
      if (!(await items.last().evaluate(el => document.activeElement === el))) throw new Error(`${label} End did not focus the last action.`);
      await items.last().click({ trial: true });
      await page.keyboard.press('Escape');
      if (await menu.evaluate(el => el.open)) throw new Error(`${label} Escape did not close action menu.`);
      if (!(await menuTrigger.evaluate(el => document.activeElement === el))) throw new Error(`${label} Escape did not return focus to menu trigger.`);
      await menuTrigger.press('Enter');
      await page.waitForFunction(el => el.open && el.querySelector('summary')?.getAttribute('aria-expanded') === 'true', await menu.elementHandle());
      await menuTrigger.press('Space');
      if (await menu.evaluate(el => el.open)) throw new Error(`${label} Space did not close the keyboard-opened menu.`);
      inspected.at(-1).menu = { trigger: menuBox, panel: menuRect, keyboardAndHitTargets: true };
    }
    return inspected;
  });

  await record('saved-workflow-descriptions-are-exact-two-line-clamped', async () => {
    await go('workflows');
    const observations = [];
    for (const [label, fixture] of Object.entries({ chinese: contract.workflowLongChinese, english: contract.workflowLongEnglish })) {
      const description = workflowRow(fixture.id).locator('.row-description').first();
      if (!(await locatorVisible(description))) throw new Error(`${label} description is absent.`);
      const observation = await description.evaluate((el) => {
        const style = getComputedStyle(el); const height = el.getBoundingClientRect().height;
        const lineHeight = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.25;
        return { rendered: el.textContent || '', lineClamp: style.webkitLineClamp, overflow: style.overflow, lineHeight, height };
      });
      if (observation.rendered !== fixture.description || observation.lineClamp !== '2' || observation.overflow !== 'hidden' || observation.height > observation.lineHeight * 2.1) throw new Error(`${label} description must keep exact saved text in two clipped lines.`);
      observations.push({ label, ...observation });
    }
    return observations;
  });

  await record('all-projects-workflow-opens-correct-definition-scope', async () => {
    await go('workflows');
    const fixture = contract.allProjectsWorkflow;
    if (!fixture.id || !fixture.project || !fixture.title) throw new Error('fixture contract allProjectsWorkflow requires id, project, title.');
    const projectSelector = page.locator('#project-selector');
    if (!(await locatorVisible(projectSelector))) throw new Error('missing project selector for all-projects scope check.');
    await projectSelector.selectOption('');
    let row = workflowRow(fixture.id);
    await row.waitFor({ state: 'visible', timeout: 8_000 });
    // Force two ordinary dashboard scope refreshes without mutating the workflow.
    await projectSelector.selectOption(fixture.project);
    await page.waitForFunction(project => window.__velaUITest?.dashboardProject === project, fixture.project);
    await projectSelector.selectOption('');
    await page.waitForFunction(() => window.__velaUITest?.dashboardProject === '');
    row = workflowRow(fixture.id);
    await row.waitFor({ state: 'visible', timeout: 8_000 });
    await row.locator('.btn-wf-inspect').click();
    const modal = page.locator('#modal-container:not(.hidden)');
    await modal.waitFor({ state: 'visible' });
    await page.waitForFunction(title => document.querySelector('#modal-title')?.textContent?.trim() === title, fixture.title);
    let text = ''; let request = null;
    try {
      text = (await modal.innerText()).trim();
      if (typeof contract.harnessTranscript === 'string' && fs.existsSync(contract.harnessTranscript)) {
        const rows = fs.readFileSync(contract.harnessTranscript, 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
        request = [...rows].reverse().find(entry => entry.method === 'workflows.get' && entry.params?.id === fixture.id) || null;
      }
    } finally {
      const close = modal.locator('#btn-close-wf-inspect-2, #btn-close-wf-inspect, [data-close-modal], .modal-close, button[aria-label*="Close"], button[aria-label*="关闭"]').first();
      if (await locatorVisible(close)) await close.click(); else await page.keyboard.press('Escape');
      await modal.waitFor({ state: 'hidden', timeout: 8_000 });
    }
    if (!text.includes(fixture.title) || !request || request.params.project !== fixture.project) throw new Error('opened definition did not request the displayed workflow using its actual project identity.');
    return { workflowId: fixture.id, displayedProject: fixture.project, requestProject: request.params.project };
  });

  await record('memory-filters-never-duplicate-header-actions', async () => {
    await go('memory');
    const filters = page.locator('.memory-filter-btn');
    const filterCount = await filters.count();
    if (filterCount < 2) throw new Error('fixture does not render enough memory filters to exercise repeat rendering.');
    const headerActionSignature = () => page.evaluate(() => [...document.querySelectorAll('.page-header .page-actions button, .page-header .memory-primary-actions button, .memory-header-actions button')]
      .filter(el => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length))
      .map(el => `${el.id}|${el.getAttribute('data-action') || ''}|${el.textContent?.trim()}`).sort());
    const initial = await headerActionSignature();
    if (!initial.length || new Set(initial).size !== initial.length) throw new Error('memory header actions are absent or duplicate before filtering.');
    for (let index = 0; index < filterCount * 2; index += 1) {
      await filters.nth(index % filterCount).click();
      const signature = await headerActionSignature();
      if (JSON.stringify(signature) !== JSON.stringify(initial) || new Set(signature).size !== signature.length) throw new Error('memory filter render duplicated or lost a header action.');
    }
    return { filters: filterCount, headerActions: initial };
  });

  await record('setup-memory-home-is-secondary-menu-route', async () => {
    await go('setup');
    const menu = page.locator('.page-header .page-actions details.action-menu').first();
    const trigger = menu.locator(':scope > summary').first();
    if (!(await locatorVisible(menu)) || !(await locatorVisible(trigger))) throw new Error('Setup has no visible secondary action menu for the Memory home route.');
    await trigger.click();
    await page.waitForFunction(() => document.querySelector('.page-header .page-actions details.action-menu')?.open === true);
    const memoryHome = menu.locator('#btn-open-setup-memory').first();
    if (!(await locatorVisible(memoryHome))) throw new Error('Setup secondary action menu does not expose the Memory home route.');
    await memoryHome.click();
    await page.waitForFunction(() => document.querySelector('.nav-link.active[data-page]')?.dataset.page === 'memory');
    if (!(await locatorVisible(page.locator('#memory-page-content')))) throw new Error('Setup Memory menu action did not render the real Memory page.');
    const legacyTab = page.locator('.setup-memory-link');
    if (await locatorVisible(legacyTab)) throw new Error('Setup still renders a duplicate Memory tab instead of using the secondary home route.');
    return { menuOpened: true, destination: 'memory', duplicateSetupTabVisible: false };
  });

  await record('settings-category-switch-preserves-unsaved-draft', async () => {
    await go('settings');
    const categories = page.locator('[data-settings-category]');
    if (await categories.count() < 2) throw new Error('settings category navigation is absent.');
    const draftCategory = page.locator('[data-settings-category="notifications"]');
    const otherCategory = page.locator('[data-settings-category="general"]');
    if (!(await locatorVisible(draftCategory)) || !(await locatorVisible(otherCategory))) throw new Error('settings needs visible notifications and general categories for draft preservation.');
    await draftCategory.click();
    const editable = page.locator('[data-settings-panel="notifications"] input:not([disabled]), [data-settings-panel="notifications"] textarea:not([disabled])').first();
    if (!(await locatorVisible(editable))) throw new Error('notifications category has no editable draft field.');
    const fieldID = await editable.getAttribute('id');
    if (!fieldID) throw new Error('settings draft field needs a stable id to verify category preservation.');
    const isCheckbox = await editable.getAttribute('type') === 'checkbox';
    const original = isCheckbox ? await editable.isChecked() : await editable.inputValue();
    const draft = isCheckbox ? !original : `${original} design-draft-${Date.now()}`;
    if (isCheckbox) await editable.setChecked(draft); else await editable.fill(draft);
    await otherCategory.click(); await draftCategory.click();
    const restored = page.locator(`#${fieldID}`).first();
    const restoredValue = isCheckbox ? await restored.isChecked() : await restored.inputValue();
    if (!(await locatorVisible(restored)) || restoredValue !== draft) throw new Error('switching settings categories discarded unsaved draft.');
    return { field: fieldID, draftRetained: true, kind: isCheckbox ? 'checkbox' : 'text' };
  });

  await record('empty-and-query-no-result-explain-next-step', async () => {
    await go('agents');
    const query = page.locator('#session-search-input');
    if (!(await locatorVisible(query))) throw new Error('session search control is absent.');
    await query.fill(`no-match-design-${Date.now()}`);
    const empty = page.locator('#sessions-empty-state');
    await empty.waitFor();
    const words = (await empty.innerText()).trim();
    const actionCount = await empty.locator('button,a').count();
    if (!words || actionCount < 1) throw new Error('query no-result state lacks explanation or a recovery action.');
    await query.fill('');
    return { queryNoResultText: words, recoveryActions: actionCount };
  });

  await record('approval-source-is-complete-not-list-truncated', async () => {
    await go('inbox');
    const fixture = contract.approval;
    if (!fixture.id || typeof fixture.sourceText !== 'string' || !fixture.sourceText) throw new Error('fixture contract approval requires id and exact nonempty sourceText.');
    const card = page.locator(`[data-testid="approval-card"][data-approval-id="${fixture.id}"]`);
    if (!(await locatorVisible(card))) throw new Error('fixture approval is not rendered.');
    const technical = card.locator('[data-testid="approval-technical-details"], details').first();
    if (await locatorVisible(technical) && !(await technical.evaluate(el => el.open))) await technical.locator('summary').click();
    const sourceToggle = card.locator('.reading-source').first();
    if (!(await locatorVisible(sourceToggle))) throw new Error('approval preview lacks a source-view control.');
    await sourceToggle.click();
    const preview = card.locator('.reading-file-source code').first();
    const raw = card.locator('[data-testid="approval-raw-json"]').first();
    if (!(await locatorVisible(preview)) || !(await locatorVisible(raw))) throw new Error('both visible file source and frozen raw-argument disclosure are required.');
    const rendered = await preview.textContent();
    if (rendered !== fixture.sourceText) throw new Error('approval file source is truncated or differs from exact frozen bytes.');
    let argumentsObject;
    try { argumentsObject = JSON.parse(await raw.textContent()); } catch { throw new Error('approval technical disclosure is not parseable frozen JSON.'); }
    if (argumentsObject.content !== fixture.sourceText) throw new Error('approval raw frozen arguments do not preserve the exact source content.');
    return { approvalId: fixture.id, sourceLength: fixture.sourceText.length, renderedLength: rendered.length, frozenArgumentsExact: true };
  });
} finally {
  report.pageErrors = pageErrors;
  report.browserClosed = true;
  try { await browser.close(); } finally {
    report.servedUISourceSHA256After = treeHashes(frozenUIPath);
    report.uiSourceUnchanged = JSON.stringify(report.servedUISourceSHA256) === JSON.stringify(report.servedUISourceSHA256After);
    report.helperSHA256After = helperPath ? createHash('sha256').update(fs.readFileSync(helperPath)).digest('hex') : setup?.helperSHA256 || null;
    report.helperUnchanged = report.helperSHA256Before !== null && report.helperSHA256Before === report.helperSHA256After;
    report.totalChecks = report.checks.length;
    report.passedChecks = report.checks.filter(check => check.passed).length;
    report.failedChecks = report.totalChecks - report.passedChecks;
    report.passed = report.failedChecks === 0 && report.uiSourceUnchanged && report.helperUnchanged && report.browserClosed;
    persist();
  }
}

if (!report.passed) process.exitCode = 1;
