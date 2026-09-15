#!/usr/bin/env node
/*
 * Browser acceptance for the activity/history shell and session detail tabs.
 *
 * Usage:
 *   node scripts/test-blume-shell-browser.mjs http://127.0.0.1:PORT \
 *     output/playwright/NEW .task-tmp/NEW/fixture.json [.task-tmp/FROZEN_UI]
 *
 * Start the existing real fixture harness first.  The fixture must be created
 * with create-ui-fixture.py --with-routing-project so project-switch behavior
 * is exercised with two synthetic projects.  This runner neither starts a
 * server nor fabricates bridge results: its wrapper records, and can hold, a
 * response only after the real local fixture bridge has returned it.
 */
import playwright from '../.task-tmp/ui-browser-tools/node_modules/playwright/index.js';
import assert from 'node:assert/strict';
import {lstat, mkdir, readFile, rm, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve, relative, sep} from 'node:path';

const [url, output, fixturePath, uiDirectory] = process.argv.slice(2);
if (!url?.startsWith('http://127.0.0.1:') || !output?.startsWith('output/playwright/') || !fixturePath) {
  throw Error('Usage: test-blume-shell-browser.mjs http://127.0.0.1:PORT output/playwright/NEW fixture.json [.task-tmp/FROZEN_UI]');
}
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const fixtureRoot = resolve(fixturePath, '..');
const project = resolve(String(fixture.project || ''));
const projects = Array.isArray(fixture.projects) ? fixture.projects.map(value => resolve(String(value))) : [];
if (!fixture.synthetic || !project.startsWith(fixtureRoot + sep) || projects.length < 2 || !projects.every(value => value.startsWith(fixtureRoot + sep))) {
  throw Error('Use a new fixture-local synthetic project created with --with-routing-project.');
}
const uiRoot = uiDirectory || 'Sources/VelaApp/Resources/UI';
if (uiDirectory && (!uiDirectory.startsWith('.task-tmp/') || uiDirectory.includes('..'))) throw Error('UI must be an owned frozen .task-tmp directory.');
await mkdir(output, {recursive: false});
const files = ['app.js', 'appearance.js', 'app.css', 'content.js', 'reading.css', 'i18n.js', 'index.html'];
const hashes = async () => Object.fromEntries(await Promise.all(files.map(async name => [name, createHash('sha256').update(await readFile(resolve(uiRoot, name))).digest('hex')])));
const browserExecutable = process.env.VELA_BROWSER_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const relationDirectory = resolve(project, '.agents/skills/review-copy');
const relationFile = resolve(relationDirectory, 'SKILL.md');
const relationSource = '---\nname: review-request-boundary\ndescription: Synthetic sibling used only to verify observed setup relations.\n---\n\nInspect the directory-local review boundary.\n';
const relationName = relationSource.match(/^name:\s*(.+)$/m)?.[1];
const relationRelativePath = relative(project, relationFile);
const relationPathFragments = [relationFile, relationRelativePath, 'review-copy/SKILL.md'];
if (!relationName) throw Error('Synthetic relation source must have a declared skill name.');
const result = {synthetic: true, native: false, completeSuite: false, expectedChecks: 7, fixture: relative(process.cwd(), fixtureRoot), sourceBefore: await hashes(), checks: [], errors: [], browserClosed: false, removedSyntheticRelation: false};
let browser, createdRelation = false;

const firstVisible = async (page, selectors, label) => {
  const selector = selectors.map(item => `${item}:visible`).join(', ');
  const target = page.locator(selector).first();
  await target.waitFor({state: 'visible'}).catch(() => { throw Error(`${label} is missing (${selector}).`); });
  return target;
};

try {
  try {
    await lstat(relationDirectory);
    throw Error('Synthetic relation directory already exists; choose a fresh fixture.');
  } catch (error) {
    if (error?.code !== 'ENOENT') throw error;
  }
  await mkdir(relationDirectory, {recursive: true});
  createdRelation = true;
  await writeFile(relationFile, relationSource, 'utf8');
  browser = await playwright.chromium.launch({headless: true, executablePath: browserExecutable});
  const context = await browser.newContext({viewport: {width: 1250, height: 800}});
  const page = await context.newPage();
  page.on('pageerror', error => result.errors.push({type: 'pageerror', message: error.message}));
  page.on('console', message => { if (message.type() === 'error') result.errors.push({type: 'console', message: message.text()}); });
  await page.goto(url);
  await page.locator('#project-selector').waitFor({state: 'visible'});
  await page.selectOption('#project-selector', project);
  await page.evaluate(() => {
    window.__blumeShellCalls = [];
    window.__blumeShellHold = null;
    const original = window.vela.call;
    window.vela.call = async (method, params = {}) => {
      const value = await original(method, params);
      window.__blumeShellCalls.push({method, params, ok: true, result: value});
      const held = window.__blumeShellHold;
      if (held?.method === method && !held.started) {
        held.started = true; held.result = value;
        await new Promise(resolve => { held.release = resolve; });
      }
      return value;
    };
  });
  const calls = () => page.evaluate(() => window.__blumeShellCalls);
  const waitForCall = async (before, methods, label) => {
    await page.waitForFunction(({before, methods}) => window.__blumeShellCalls.slice(before).some(call => call.ok && methods.includes(call.method)), {before, methods});
    const matched = (await calls()).slice(before).find(call => call.ok && methods.includes(call.method));
    assert.ok(matched, `${label}: expected a successful real bridge response.`);
    return matched;
  };
  const activeAgentTab = async name => {
    const value = name === 'activity' ? 'sessions' : 'recent';
    const tab = page.locator(`[data-agentstab="${value}"]`);
    await tab.click();
    await page.waitForFunction(value => document.querySelector(`[data-agentstab="${value}"]`)?.classList.contains('active'), value);
    return tab;
  };
  const openAgents = async () => {
    await page.locator('.nav-link[data-page="agents"]:visible, .companion-link[data-page="agents"]:visible').first().click();
    await page.locator('.nav-link[data-page="agents"].active:visible, .companion-link[data-page="agents"].active:visible').first().waitFor();
  };
  const primarySession = async () => {
    const button = page.locator('.session-title-btn').first();
    await button.waitFor({state: 'visible'});
    return button;
  };
  const assertNoOverflow = async (label) => {
    const geometry = await page.evaluate(() => ({width: innerWidth, scrollWidth: document.documentElement.scrollWidth, bodyScrollWidth: document.body.scrollWidth}));
    assert.ok(geometry.scrollWidth <= geometry.width && geometry.bodyScrollWidth <= geometry.width, `${label}: document must not overflow horizontally.`);
    return geometry;
  };
  const routeReadiness = {
    agents: '#agents-tab-content', workflows: '#workflows-tab-content', setup: '#setup-tab-content',
    usage: '#usage-codex-quota-card', improve: '.improve-container', lab: '#lab-tab-content',
    inbox: '#approval-list', memory: '#memory-page-content', settings: '#setting-locale'
  };
  const navigateEveryVisibleRoute = async (selector, surface) => {
    const routes = [...new Set(await page.locator(selector).evaluateAll(links => links.filter(link => Boolean(link.offsetWidth || link.offsetHeight || link.getClientRects().length)).map(link => link.dataset.page).filter(Boolean)))];
    assert.ok(routes.length > 0, `${surface}: no visible routes were rendered.`);
    for (const route of routes) {
      const link = page.locator(`${selector}[data-page="${route}"]:visible`).first();
      await link.click();
      await page.waitForFunction(expected => document.querySelector('.nav-link.active')?.dataset.page === expected, route);
      const readiness = routeReadiness[route];
      assert.ok(readiness, `${surface}/${route}: missing a route-specific readiness contract.`);
      await page.locator(readiness).first().waitFor({state: 'visible'});
    }
    return routes;
  };

  for (const locale of ['en', 'zh-CN']) {
    // The compact companion shell intentionally hides the desktop sidebar.
    // Restore the workspace viewport before using that sidebar for locale setup.
    await page.setViewportSize({width: 1250, height: 800});
    await page.locator('.nav-link[data-page="settings"]').click();
    const general = await firstVisible(page, ['[data-settings-category="general"]'], 'general settings category');
    await general.click();
    const localeSelect = page.locator('#setting-locale');
    await localeSelect.waitFor({state: 'visible'});
    await localeSelect.selectOption(locale);
    await page.waitForFunction(expected => document.getElementById('setting-locale')?.value === expected, locale);
    for (const viewport of [[1250, 800], [440, 760]]) {
      await page.setViewportSize({width: viewport[0], height: viewport[1]});
      await openAgents();
      await activeAgentTab('activity');
      await assertNoOverflow(`${locale}-${viewport.join('x')}`);
      await page.screenshot({animations: 'disabled', path: `${output}/shell-${locale}-${viewport[0]}x${viewport[1]}-activity.png`});
    }
  }
  result.checks.push({name: 'both-locales-and-supported-workspace-companion-sizes-have-no-horizontal-overflow', passed: true});

  await page.setViewportSize({width: 1250, height: 800});
  await openAgents();
  const dashboardBeforeSplit = (await calls()).length;
  await page.evaluate(() => window.dispatchEvent(new Event('vela:refresh')));
  const dashboardCall = await waitForCall(dashboardBeforeSplit, ['dashboard.get'], 'session split dashboard refresh');
  const dashboardSessions = Array.isArray(dashboardCall.result?.sessions) ? dashboardCall.result.sessions : [];
  const projectSessions = dashboardSessions.filter(session => session?.project === project && typeof session.id === 'string');
  const activityStates = new Set(['running', 'needs approval', 'needs_approval', 'error', 'failed']);
  const expectedActivityIDs = projectSessions.filter(session => activityStates.has(String(session.state || '').trim().toLowerCase())).map(session => session.id).sort();
  const expectedHistoryIDs = projectSessions.filter(session => !activityStates.has(String(session.state || '').trim().toLowerCase())).map(session => session.id).sort();
  assert.equal(new Set(expectedActivityIDs).size, expectedActivityIDs.length, 'Fixture dashboard returned duplicate activity session IDs.');
  assert.equal(new Set(expectedHistoryIDs).size, expectedHistoryIDs.length, 'Fixture dashboard returned duplicate history session IDs.');
  await activeAgentTab('activity');
  await page.waitForFunction(expected => JSON.stringify([...document.querySelectorAll('.session-card')].map(card => card.dataset.id).filter(Boolean).sort()) === JSON.stringify(expected), expectedActivityIDs);
  const activityIds = await page.locator('.session-card').evaluateAll(cards => cards.map(card => card.dataset.id).filter(Boolean).sort());
  await activeAgentTab('history');
  await page.waitForFunction(expected => JSON.stringify([...document.querySelectorAll('.session-card')].map(card => card.dataset.id).filter(Boolean).sort()) === JSON.stringify(expected), expectedHistoryIDs);
  const historyIds = await page.locator('.session-card').evaluateAll(cards => cards.map(card => card.dataset.id).filter(Boolean).sort());
  assert.deepEqual(activityIds, expectedActivityIDs, 'Activity IDs must equal the real dashboard states that require active attention.');
  assert.deepEqual(historyIds, expectedHistoryIDs, 'History IDs must equal the complementary real dashboard session IDs.');
  assert.equal(activityIds.filter(id => historyIds.includes(id)).length, 0, 'Activity and History must not overlap.');
  assert.deepEqual([...activityIds, ...historyIds].sort(), projectSessions.map(session => session.id).sort(), 'Activity and History must not lose project sessions.');
  result.checks.push({name: 'activity-and-history-partition-real-dashboard-session-states', passed: true, activityCount: activityIds.length, historyCount: historyIds.length});

  const codexSession = projectSessions.find(session => session.provider === 'codex');
  assert.ok(codexSession, 'Fixture must have a real Codex record for supported relation lookup.');
  // 560px is the native window minimum height.  Use it here so restoration is
  // exercised on the real page scroll surface instead of comparing two zeroes.
  await page.setViewportSize({width: 1250, height: 560});
  await activeAgentTab(activityStates.has(String(codexSession.state || '').trim().toLowerCase()) ? 'activity' : 'history');
  const trigger = page.locator(`.session-title-btn[data-id="${codexSession.id}"]`);
  await trigger.focus();
  const triggerId = await trigger.getAttribute('data-id');
  const scrollBeforeDetail = await page.evaluate(() => {
    const surface = document.getElementById('page-container');
    if (!surface) throw Error('Missing the page-container scroll surface.');
    const overflow = getComputedStyle(surface).overflowY;
    if (!['auto', 'scroll'].includes(overflow) || surface.clientHeight <= 0) throw Error('page-container is not the active page scroll surface.');
    const maximum = surface.scrollHeight - surface.clientHeight;
    if (maximum <= 0) throw Error('Fixture does not make the real page scroll surface scrollable; cannot verify scroll restoration.');
    surface.scrollTop = Math.min(96, maximum);
    return {top: surface.scrollTop, maximum};
  });
  const callsBeforeDetail = (await calls()).length;
  await trigger.click();
  const drawer = page.locator('#detail-drawer:not(.hidden)');
  await drawer.waitFor({state: 'visible'});
  const planResponse = await waitForCall(callsBeforeDetail, ['sessions.plan.get'], 'session Plan background load');
  const planTab = drawer.locator('[data-session-detail-tab="plan"]');
  await planTab.waitFor({state: 'visible'});
  await planTab.click();
  const planPanel = drawer.locator('#session-panel-plan:not([hidden])');
  await planPanel.waitFor({state: 'visible'});
  const planItems = await planPanel.locator('[data-plan-item], .session-plan-item, .plan-item').count();
  const agentTabDetail = drawer.locator('[data-session-detail-tab="agents"]');
  await agentTabDetail.waitFor({state: 'visible'});
  await agentTabDetail.click();
  const relationResponse = await waitForCall(callsBeforeDetail, ['sessions.relations.get'], 'session Sub-agents background load');
  const agentsPanel = drawer.locator('#session-panel-agents:not([hidden])');
  await agentsPanel.waitFor({state: 'visible'});
  const relationItems = await agentsPanel.locator('.session-relation-link, [data-relation-item]').count();
  await page.locator('#btn-close-drawer').click();
  await page.waitForFunction(id => document.activeElement?.getAttribute('data-id') === id, triggerId);
  const scrollAfterDetail = await page.evaluate(() => document.getElementById('page-container')?.scrollTop ?? null);
  assert.equal(scrollAfterDetail, scrollBeforeDetail.top, 'Closing session detail must restore the prior list scroll position.');
  result.checks.push({name: 'plan-and-subagents-tabs-wait-for-real-background-data-and-restore-list-focus-scroll', passed: true,
    planState: planResponse.result?.state || 'unknown', relationState: relationResponse.result?.relation?.headerState || 'unknown', planItems, relationItems, scrollMaximum: scrollBeforeDetail.maximum});

  await openAgents();
  const routeProjects = projects.filter(value => value !== project);
  await page.selectOption('#project-selector', routeProjects[0]);
  await page.waitForFunction(expected => document.getElementById('project-selector')?.value === expected, routeProjects[0]);
  await page.locator('.nav-link[data-page="inbox"]').click();
  await page.locator('.nav-link[data-page="inbox"].active').waitFor({state: 'visible'});
  assert.equal(await page.locator('#project-selector').inputValue(), routeProjects[0], 'Route transition must retain the selected project.');
  await page.selectOption('#project-selector', project);
  await page.locator('.nav-link[data-page="setup"]').click();
  await page.locator('#btn-scan-setup').click();
  await page.waitForFunction(() => window.__blumeShellCalls.some(call => call.method === 'setup.scan' && call.ok));
  result.checks.push({name: 'project-selector-stays-synchronized-through-shell-routes', passed: true});

  const reviewRow = page.locator('article.workspace-row.asset-row').filter({hasText: 'review'}).first();
  await reviewRow.waitFor({state: 'visible'});
  const reviewOpen = reviewRow.locator('.btn-preview-artifact, .btn-setup-view, .row-title').first();
  let relationSurface = null;
  let relationCallsBefore = (await calls()).length;
  if (await reviewOpen.count() && await reviewOpen.isVisible()) {
    await reviewOpen.click();
    const relatedTabs = page.locator('[data-artifact-tab="related"]');
    if (await relatedTabs.count() && await relatedTabs.first().isVisible()) {
      await relatedTabs.first().click();
      relationSurface = page.locator('#detail-drawer:not(.hidden)');
    } else {
      await page.locator('#btn-close-drawer').click();
      await page.locator('#detail-drawer').waitFor({state: 'hidden'});
    }
  }
  if (!relationSurface) {
    relationCallsBefore = (await calls()).length;
    const more = reviewRow.locator('.btn-setup-more').first();
    if (await more.count() && await more.isVisible()) await more.click();
    const relationAction = await firstVisible(reviewRow, ['.btn-setup-action-relations', '.btn-setup-relations'], 'setup relations action');
    await relationAction.click();
    relationSurface = page.locator('#modal-container:not(.hidden)');
    await relationSurface.waitFor({state: 'visible'});
  }
  const relationsCall = await waitForCall(relationCallsBefore, ['setup.relations'], 'setup relationship details');
  const observedRelations = Array.isArray(relationsCall.result?.relations) ? relationsCall.result.relations : [];
  const expectedRelation = observedRelations.find(item => {
    const observedPath = String(item?.path || '');
    return item?.relation === 'same_declared_skill_name' && (observedPath === relationFile || observedPath.endsWith('/' + relationRelativePath));
  });
  assert.ok(expectedRelation, `The real setup.relations response must report the source-derived declared name ${relationName} as a same-name skill relation.`);
  const relationText = await relationSurface.textContent();
  assert.ok(relationPathFragments.some(path => (relationText || '').includes(path)), 'Relationship details must render the source-derived sibling skill path.');
  if (await page.locator('#modal-container').isVisible()) await page.locator('#btn-close-modal').click();
  if (await page.locator('#btn-close-drawer').isVisible()) await page.locator('#btn-close-drawer').click();
  result.checks.push({name: 'setup-same-name-skill-relation-is-loaded-through-real-scan-and-details', passed: true});

  await page.setViewportSize({width: 1250, height: 800});
  const desktopRoutes = await navigateEveryVisibleRoute('.nav-link[data-page]', 'desktop shell');
  await page.setViewportSize({width: 440, height: 760});
  const visibleCompanionRoutes = await page.locator('.companion-link[data-page]').evaluateAll(links => links.filter(link => Boolean(link.offsetWidth || link.offsetHeight || link.getClientRects().length)).map(link => link.dataset.page).filter(Boolean));
  assert.deepEqual(visibleCompanionRoutes.sort(), ['agents','improve','setup','usage'], 'All four core companion routes must be visible.');
  const companionRoutes = await navigateEveryVisibleRoute('.companion-link[data-page]', 'companion shell');
  for (const route of ['workflows','inbox','memory','lab','settings']) {
    await page.locator('.companion-nav .action-menu > summary').click();
    await page.locator(`.companion-link[data-page="${route}"]`).click();
    await page.waitForFunction(expected => document.querySelector('.nav-link.active')?.dataset.page === expected, route);
    companionRoutes.push(route);
  }
  assert.deepEqual(companionRoutes.sort(), desktopRoutes.sort(), 'All desktop routes remain reachable in the companion shell.');
  result.checks.push({name: 'all-visible-desktop-and-companion-routes-are-reachable-with-a-content-container', passed: true, desktopRoutes, companionRoutes});

  const callCountBeforeHold = (await calls()).length;
  await page.evaluate(() => { window.__blumeShellHold = {method: 'dashboard.get', started: false, release: null}; });
  await page.evaluate(() => window.dispatchEvent(new Event('vela:refresh')));
  await page.waitForFunction(() => window.__blumeShellHold?.started === true);
  await page.setViewportSize({width: 1250, height: 800});
  await page.locator('.nav-link[data-page="setup"]').click();
  await page.evaluate(() => window.__blumeShellHold.release());
  await page.locator('.nav-link[data-page="setup"].active').waitFor({state: 'visible'});
  assert.ok((await calls()).slice(callCountBeforeHold).some(call => call.method === 'dashboard.get' && call.ok), 'Held-response check must release a real dashboard response.');
  await assertNoOverflow('post-held-response');
  result.checks.push({name: 'late-real-dashboard-response-does-not-displace-a-newer-route', passed: true});
} catch (error) {
  result.errors.push({type: 'assertion', message: error.stack || String(error)});
  process.exitCode = 1;
} finally {
  try { if (createdRelation) { await rm(relationDirectory, {recursive: true, force: true}); result.removedSyntheticRelation = true; } }
  catch (error) { result.errors.push({type: 'fixture-cleanup', message: error.message}); process.exitCode = 1; }
  if (browser) { await browser.close(); result.browserClosed = true; }
  result.sourceAfter = await hashes();
  result.sourceUnchanged = JSON.stringify(result.sourceBefore) === JSON.stringify(result.sourceAfter);
  result.passed = result.checks.length === result.expectedChecks && result.errors.length === 0 && result.sourceUnchanged && result.removedSyntheticRelation && result.browserClosed;
  await writeFile(output + '/results.json', JSON.stringify(result, null, 2));
  console.log(JSON.stringify({passed: result.passed, checks: result.checks.length, errors: result.errors, output}));
  if (!result.passed) process.exitCode = 1;
}
