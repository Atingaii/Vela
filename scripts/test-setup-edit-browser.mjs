#!/usr/bin/env node
/* Real UI consumer for Setup editing. Requires a fixture bridge that exposes setup.edit.*. */
import playwright from '../.task-tmp/ui-browser-tools/node_modules/playwright/index.js';
import assert from 'node:assert/strict';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve, relative, sep} from 'node:path';

const [url, output, fixturePath, uiDirectory] = process.argv.slice(2);
if (!url?.startsWith('http://127.0.0.1:') || !output?.startsWith('output/playwright/') || !fixturePath) {
  throw Error('Usage: test-setup-edit-browser.mjs http://127.0.0.1:PORT output/playwright/NEW fixture.json [.task-tmp/FROZEN_UI]');
}
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const fixtureRoot = resolve(fixturePath, '..');
const project = resolve(String(fixture.project || ''));
const target = resolve(project, '.agents/skills/review/SKILL.md');
if (!fixture.synthetic || !project.startsWith(fixtureRoot + sep) || !target.startsWith(project + sep)) {
  throw Error('Use only a new synthetic fixture-local Harbor skill.');
}
const uiRoot = uiDirectory || 'Sources/VelaApp/Resources/UI';
if (uiDirectory && (!uiDirectory.startsWith('.task-tmp/') || uiDirectory.includes('..'))) throw Error('UI must be an owned frozen .task-tmp directory.');
await mkdir(output, {recursive: false});
const files = ['app.js','app.css','content.js','reading.css','i18n.js','index.html'];
const EXPECTED_CHECKS = 13;
const hashes = async () => Object.fromEntries(await Promise.all(files.map(async name => [name, createHash('sha256').update(await readFile(resolve(uiRoot, name))).digest('hex')])));
const sha = value => createHash('sha256').update(value).digest('hex');
const browserExecutable = process.env.VELA_BROWSER_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const waitForSource = async (path, expected, label) => {
  const deadline = Date.now() + 8000;
  let actual = '';
  do {
    actual = await readFile(path, 'utf8');
    if (actual === expected) return;
    await new Promise(resolve => setTimeout(resolve, 50));
  } while (Date.now() < deadline);
  throw new Error(`${label}: source did not reach the expected exact bytes; got SHA-256 ${sha(actual)}.`);
};
const initial = await readFile(target, 'utf8');
const originalHash = sha(initial);
const originalBlock = 'Inspect the diff and the assertion that covers invalid input.\n';
const replacement = 'Inspect the reviewed diff, then verify the invalid-input assertion.\n';
if (!initial.includes(originalBlock)) throw Error('Fixture skill no longer has the exact synthetic edit target.');
const expected = initial.replace(originalBlock, replacement);
const result = {synthetic: true, native: false, expectedChecks: EXPECTED_CHECKS, fixture: relative(process.cwd(), fixtureRoot), target: relative(project, target), sourceBefore: await hashes(), initialHash: originalHash, checks: [], errors: [], browserClosed: false, restoredFixtureSource: false};
let browser;
try {
  browser = await playwright.chromium.launch({headless: true, executablePath: browserExecutable});
  const context = await browser.newContext({viewport: {width: 1250, height: 800}});
  const page = await context.newPage();
  page.on('pageerror', error => result.errors.push({type: 'pageerror', message: error.message}));
  await page.goto(url);
  await page.locator('.session-card').first().waitFor({state: 'visible'});
  await page.evaluate(() => {
    window.__setupEditCalls = [];
    window.__setupPrepareGate = null;
    window.__setupEditListeners = new Set();
    const addListener = window.addEventListener.bind(window), removeListener = window.removeEventListener.bind(window);
    window.addEventListener = (type, callback, options) => {
      if (type === 'vela:setup-edit-request-settled') window.__setupEditListeners.add(callback);
      return addListener(type, callback, options);
    };
    window.removeEventListener = (type, callback, options) => {
      if (type === 'vela:setup-edit-request-settled') window.__setupEditListeners.delete(callback);
      return removeListener(type, callback, options);
    };
    const call = window.vela.call;
    window.vela.call = async (method, params = {}) => {
      try {
        const value = await call(method, params);
        // The gate delays only delivery to the renderer. The real strict bridge
        // and helper have already executed setup.edit.prepare at this point.
        const gate = method === 'setup.edit.prepare' ? window.__setupPrepareGate : null;
        if (gate?.holdNext) {
          gate.holdNext = false; gate.started = true; gate.realResult = value;
          await new Promise(resolve => { gate.release = resolve; });
        }
        window.__setupEditCalls.push({method, params, ok: true, result: value});
        return value;
      } catch (error) { window.__setupEditCalls.push({method, params, ok: false, error: String(error?.message || error)}); throw error; }
    };
  });
  const calls = () => page.evaluate(() => window.__setupEditCalls);
  const selectKnownLocale = async locale => {
    await page.locator('.nav-link[data-page="settings"]').click();
    const general = page.locator('[data-settings-category="general"]');
    await general.waitFor({state: 'visible'});
    await general.click();
    const select = page.locator('#setting-locale');
    await select.waitFor({state: 'visible'});
    await select.selectOption(locale);
    await page.waitForFunction(expected => document.getElementById('setting-locale')?.value === expected, locale);
  };
  const currentReader = drawer => drawer.locator('[data-setup-document] .reading-file').first();
  const pendingSetupApproval = async () => {
    const prepared = (await calls()).filter(row => row.method === 'setup.edit.prepare' && row.ok).at(-1);
    const id = prepared?.result?.approval?.id;
    assert.ok(typeof id === 'string' && id.length > 0, 'setup.edit.prepare must return the rendered pending approval ID.');
    return page.locator(`[data-testid="approval-card"][data-tool="setup.file.edit"][data-approval-id="${id}"]`);
  };
  const showReaderSource = async drawer => {
    const reader = currentReader(drawer);
    await reader.waitFor({state: 'visible'});
    await reader.locator('.reading-source').click();
    await reader.locator('.reading-file-source').waitFor({state: 'visible'});
    // A valid zero-byte file has an attached but zero-area <code> node.
    await reader.locator('.reading-file-source code').waitFor({state: 'attached'});
    return reader;
  };
  await selectKnownLocale('en');
  const locateSkillRow = async () => {
    const matches = await page.locator('article.workspace-row.asset-row').evaluateAll((rows, exactPath) => rows
      .filter(row => row.querySelector('.row-title')?.textContent?.trim() === 'review' &&
                     row.querySelector('[data-testid="asset-location"]')?.getAttribute('title') === exactPath)
      .map(row => row.getAttribute('data-asset-id')), target);
    assert.equal(matches.length, 1, 'Fixture project must expose exactly one review/SKILL.md row with its exact owned source path.');
    return page.locator(`article.workspace-row.asset-row[data-asset-id="${matches[0]}"]`);
  };
  const openSkill = async () => {
    const close = page.locator('#btn-close-drawer');
    if (await close.isVisible()) { await close.click(); await page.locator('#detail-drawer').waitFor({state: 'hidden'}); }
    await page.locator('.nav-link[data-page="setup"]').click();
    await page.locator('[data-setuptab="skills"]').click();
    const row = await locateSkillRow();
    await row.locator('.row-title.btn-preview-artifact').click();
    await page.locator('#detail-drawer:not(.hidden) [data-setup-document] .reading-file[data-view="preview"]').waitFor({state: 'visible'});
    await page.locator('#detail-drawer:not(.hidden) #btn-setup-edit').waitFor({state: 'visible'});
    return page.locator('#detail-drawer:not(.hidden)');
  };
  const scanSetup = async () => {
    const close = page.locator('#btn-close-drawer');
    if (await close.isVisible()) { await close.click(); await page.locator('#detail-drawer').waitFor({state: 'hidden'}); }
    await page.locator('.nav-link[data-page="setup"]').click();
    const before = (await calls()).filter(row => row.method === 'setup.scan' && row.ok).length;
    await page.locator('#btn-scan-setup').click();
    await page.waitForFunction(count => window.__setupEditCalls.filter(row => row.method === 'setup.scan' && row.ok).length > count, before);
    await page.locator('[data-setuptab="skills"]').click();
    await locateSkillRow();
  };
  const openEditor = async (fromBlock = false) => {
    const drawer = await openSkill();
    if (fromBlock) {
      const block = drawer.locator('.setup-editable-block').filter({hasText: 'Inspect the diff'}).locator('.btn-edit-setup-block');
      await block.click();
    } else {
      await page.locator('#btn-setup-edit').click();
    }
    const textarea = page.locator('#setup-editor-source');
    await textarea.waitFor({state: 'visible'});
    const editTarget = page.locator('[data-testid="setup-edit-target"]');
    await editTarget.waitFor({state: 'visible'});
    const targetText = (await editTarget.textContent() || '').trim();
    assert.ok(targetText.includes('Harbor') && targetText.includes('.agents/skills/review/SKILL.md'), 'editor target must name the owned project and relative source.');
    assert.ok(!targetText.includes(project) && !targetText.includes(fixtureRoot), 'editor target must not expose the absolute fixture path.');
    return textarea;
  };
  const source = await openSkill();
  const initialReader = await showReaderSource(source);
  assert.equal(await initialReader.locator('.reading-file-source code').textContent(), initial);
  await initialReader.locator('.reading-preview').click();
  const area = await openEditor(true);
  assert.equal(await area.inputValue(), originalBlock);
  await area.fill(replacement);
  assert.equal(await readFile(target, 'utf8'), initial);
  await page.locator('[data-edit-view="preview"]').click();
  const preview = page.locator('#setup-editor-preview');
  const previewReader = preview.locator('.reading-file').first();
  await previewReader.waitFor({state: 'visible'});
  await previewReader.locator('.reading-source').click();
  await page.waitForFunction(() => document.querySelector('#setup-editor-preview .reading-file')?.dataset.view === 'source');
  assert.equal(await previewReader.locator('.reading-file-source code').textContent(), expected);
  result.checks.push({name: 'block-edit-preserves-unselected-source-bytes', passed: true, expectedHash: sha(expected)});

  await page.locator('[data-edit-view="diff"]').click();
  const diff = page.locator('#setup-editor-diff');
  await diff.locator('[data-review-complete="true"]').waitFor({state: 'visible'});
  assert.equal(await diff.locator('[data-review-complete="false"]').count(), 0);
  const reviewCalls = (await calls()).filter(row => row.method === 'setup.edit.preview');
  assert.equal(reviewCalls.length, 1);
  assert.deepEqual(reviewCalls[0].params.content, expected);
  assert.equal(await diff.locator('.reading-change-removed code').textContent(), originalBlock);
  assert.equal(await diff.locator('.reading-change-added code').textContent(), replacement);
  await page.screenshot({path: output + '/review-diff.png'});
  result.checks.push({name: 'preview-is-helper-backed-complete-diff', passed: true});

  assert.equal((await calls()).filter(row => row.method === 'setup.edit.prepare').length, 0);
  await page.locator('#btn-setup-request').click();
  await page.locator('.nav-link[data-page="inbox"].active').waitFor();
  assert.equal(await readFile(target, 'utf8'), initial);
  const prepareCalls = (await calls()).filter(row => row.method === 'setup.edit.prepare');
  assert.equal(prepareCalls.length, 1);
  assert.deepEqual(prepareCalls[0].params.content, expected);
  const approval = await pendingSetupApproval();
  await approval.waitFor({state: 'visible'});
  result.checks.push({name: 'prepare-keeps-source-unchanged-and-creates-rendered-approval', passed: true});

  const dashboardBeforeApproval = (await calls()).filter(row => row.method === 'dashboard.get').length;
  await approval.locator('[data-testid="approval-approve"]').click();
  await page.waitForFunction(() => window.__setupEditCalls.some(row => row.method === 'approvals.decide' && row.ok));
  await waitForSource(target, expected, 'approval did not apply the reviewed setup edit');
  await page.waitForFunction(before => window.__setupEditCalls.filter(row => row.method === 'dashboard.get').length > before, dashboardBeforeApproval);
  const decisions = (await calls()).filter(row => row.method === 'approvals.decide' && row.ok);
  assert.equal(decisions.length, 1);
  const appliedDrawer = await openSkill();
  const appliedReader = await showReaderSource(appliedDrawer);
  assert.equal(await appliedReader.locator('.reading-file-source code').textContent(), expected);
  result.checks.push({name: 'inbox-approval-applies-exact-reviewed-source', passed: true});

  const afterEdit = await openSkill();
  await page.locator('#detail-drawer:not(.hidden) .setup-edit-history-row .btn-setup-undo').waitFor({state: 'visible'});
  const dashboardBeforeUndo = (await calls()).filter(row => row.method === 'dashboard.get').length;
  await page.locator('#detail-drawer:not(.hidden) .btn-setup-undo').click();
  await page.locator('#btn-setup-confirm-undo').click();
  await waitForSource(target, initial, 'undo did not restore the original setup source');
  await page.waitForFunction(before => window.__setupEditCalls.filter(row => row.method === 'dashboard.get').length > before, dashboardBeforeUndo);
  const undoneDrawer = await openSkill();
  const undoneReader = await showReaderSource(undoneDrawer);
  assert.equal(await undoneReader.locator('.reading-file-source code').textContent(), initial);
  result.checks.push({name: 'history-and-ui-undo-restore-exact-original-source', passed: true});

  const draftArea = await openEditor();
  const draftText = originalBlock.replace('assertion', 'draft assertion');
  const draftDocument = initial.replace(originalBlock, draftText);
  await draftArea.fill(draftDocument);
  await page.locator('#btn-setup-editor-close').click();
  const reopened = await openEditor();
  assert.equal(await reopened.inputValue(), draftDocument);
  await page.locator('#btn-setup-editor-close').click();
  await selectKnownLocale('zh-CN');
  await page.locator('.nav-link[data-page="setup"]').click();
  const zhReopened = await openEditor();
  assert.equal(await zhReopened.inputValue(), draftDocument);
  await page.locator('#btn-setup-editor-close').click();
  await selectKnownLocale('en');
  result.checks.push({name: 'draft-survives-close-reopen-and-locale-switch', passed: true});

  const external = initial.replace('invalid input.', 'external disk change.');
  await writeFile(target, external, 'utf8');
  await scanSetup();
  const staleArea = await openEditor();
  await page.locator('.alert-banner #btn-setup-rebase').waitFor({state: 'visible'});
  assert.equal(await staleArea.inputValue(), draftDocument);
  await page.locator('#btn-setup-rebase').click();
  for (const key of ['setupEdit.savedDraft', 'setupEdit.diskVersion']) {
    const label = page.locator(`#setup-editor-preview [data-i18n="${key}"]`);
    await label.waitFor({state: 'visible'});
    assert.equal(await label.textContent(), await page.evaluate(name => window.VelaI18n.t(name), key));
  }
  result.checks.push({name: 'external-change-surfaces-stale-base-and-preserves-draft', passed: true});

  // A pending approval is frozen against its original source. Mutating the
  // fixture file afterwards must surface the helper's failed execution in the
  // Inbox, never replace the external bytes or show an approval success toast.
  await page.locator('#btn-setup-discard').click();
  await writeFile(target, initial, 'utf8');
  await scanSetup();
  const staleCandidate = initial.replace(originalBlock, 'Reviewed candidate that must not overwrite an external edit.\n');
  const staleApprovalArea = await openEditor();
  await staleApprovalArea.fill(staleCandidate);
  await page.locator('[data-edit-view="diff"]').click();
  await page.locator('#setup-editor-diff [data-review-complete="true"]').waitFor({state: 'visible'});
  await page.locator('#btn-setup-request').click();
  await page.locator('.nav-link[data-page="inbox"].active').waitFor();
  const staleApproval = await pendingSetupApproval();
  await staleApproval.waitFor({state: 'visible'});
  const externalAfterPrepare = 'External edit after a reviewed approval.\n';
  await writeFile(target, externalAfterPrepare, 'utf8');
  const decisionsBeforeStale = (await calls()).filter(row => row.method === 'approvals.decide').length;
  await staleApproval.locator('[data-testid="approval-approve"]').click();
  await page.waitForFunction(count => window.__setupEditCalls.filter(row => row.method === 'approvals.decide').length > count, decisionsBeforeStale);
  await page.locator('[data-testid="toast"][data-toast-key^="error:inbox.executionFailed:"]').waitFor({state: 'visible'});
  const staleDecision = (await calls()).filter(row => row.method === 'approvals.decide').at(-1);
  assert.equal(staleDecision.result?.state, 'failed');
  assert.equal(await readFile(target, 'utf8'), externalAfterPrepare);
  assert.equal(await page.locator('[data-testid="toast"][data-toast-key^="info:inbox.approvedToast:"]').count(), 0);
  await page.screenshot({path: output + '/stale-approval-failed.png'});
  result.checks.push({name: 'external-change-after-prepare-fails-inbox-without-overwrite-or-success-toast', passed: true, externalHash: sha(externalAfterPrepare)});

  // Deliver a real helper prepare response late, after the user closes and
  // reopens. The browser gate delays delivery only; it never fabricates a
  // success response or bypasses the strict fixture bridge.
  await writeFile(target, initial, 'utf8');
  await scanSetup();
  const firstLateContent = initial.replace(originalBlock, 'First reviewed request held at the renderer boundary.\n');
  const lateArea = await openEditor();
  await lateArea.fill(firstLateContent);
  await page.locator('[data-edit-view="diff"]').click();
  await page.locator('#setup-editor-diff [data-review-complete="true"]').waitFor({state: 'visible'});
  await page.evaluate(() => { window.__setupPrepareGate = {holdNext: true, started: false, release: null, realResult: null}; });
  await page.locator('#btn-setup-request').click();
  await page.waitForFunction(() => window.__setupPrepareGate?.started === true && Boolean(window.__setupPrepareGate.realResult?.approval?.id));
  await page.locator('#btn-setup-editor-close').click();
  await page.locator('#modal-container').waitFor({state: 'hidden'});
  const reopenedLate = await openEditor();
  assert.equal(await reopenedLate.inputValue(), firstLateContent);
  await page.locator('#setup-edit-request-state[data-i18n="setupEdit.requestPending"]').waitFor({state: 'visible'});
  assert.equal(await page.locator('#btn-setup-review').isDisabled(), true, 'the identical in-flight request must not be submitted twice.');
  const secondLateContent = initial.replace(originalBlock, 'A later distinct draft must survive the earlier response.\n');
  await reopenedLate.fill(secondLateContent);
  assert.equal(await page.locator('#btn-setup-review').isDisabled(), false, 'an explicitly changed draft may be reviewed after the original request settles.');
  await page.evaluate(() => window.__setupPrepareGate.release());
  await page.waitForFunction(expected => document.querySelector('#setup-editor-source')?.value === expected && !document.getElementById('btn-setup-review')?.disabled, secondLateContent);
  assert.equal(await reopenedLate.inputValue(), secondLateContent);
  await page.locator('[data-edit-view="diff"]').click();
  await page.locator('#setup-editor-diff [data-review-complete="true"]').waitFor({state: 'visible'});
  await page.locator('#btn-setup-request').click();
  await page.locator('.nav-link[data-page="inbox"].active').waitFor({state: 'visible'});
  const latePrepareCalls = (await calls()).filter(row => row.method === 'setup.edit.prepare' && row.ok);
  assert.ok(latePrepareCalls.filter(row => row.params.content === firstLateContent).length === 1, 'the held exact draft must create only one real approval.');
  assert.ok(latePrepareCalls.filter(row => row.params.content === secondLateContent).length === 1, 'the later changed draft must create one separate real approval.');
  const latestApproval = await pendingSetupApproval();
  const decisionsBeforeReject = (await calls()).filter(row => row.method === 'approvals.decide' && row.ok).length;
  await latestApproval.locator('[data-testid="approval-reject"]').click();
  await page.waitForFunction(count => window.__setupEditCalls.filter(row => row.method === 'approvals.decide' && row.ok).length > count, decisionsBeforeReject);
  const retryArea = await openEditor();
  await retryArea.fill(secondLateContent);
  assert.equal(await page.locator('#setup-edit-request-state').isVisible(), false, 'fresh setup.edit.get must release a rejected same-payload request gate.');
  assert.equal(await page.locator('#btn-setup-review').isDisabled(), false, 'the same content may be reviewed again after its prior approval was rejected.');
  await page.locator('#btn-setup-discard').click();
  result.checks.push({name: 'late-real-prepare-close-reopen-preserves-distinct-draft-prevents-duplicate-and-releases-terminal-request', passed: true});

  // A zero-byte source is still an editable whole document. Its review and
  // approval stay fully UI-driven; filesystem writes only establish the
  // documented external fixture state and verify exact resulting bytes.
  await writeFile(target, '', 'utf8');
  await scanSetup();
  const emptyReplacement = '# New document\n\nCreated from an empty reviewed source.\n';
  const emptyArea = await openEditor();
  assert.equal(await emptyArea.inputValue(), '');
  await emptyArea.fill(emptyReplacement);
  await page.locator('[data-edit-view="diff"]').click();
  const emptyDiff = page.locator('#setup-editor-diff [data-review-complete="true"]');
  await emptyDiff.waitFor({state: 'visible'});
  assert.equal(await emptyDiff.locator('.reading-change-added code').textContent(), emptyReplacement);
  await page.locator('#btn-setup-request').click();
  await page.locator('.nav-link[data-page="inbox"].active').waitFor();
  const emptyApproval = await pendingSetupApproval();
  await emptyApproval.waitFor({state: 'visible'});
  await emptyApproval.locator('.setup-approval-change [data-review-complete="true"]').waitFor({state: 'visible'});
  await emptyApproval.locator('.setup-approval-change details summary').click();
  assert.equal(await emptyApproval.locator('.setup-approval-change .reading-file-source code').textContent(), emptyReplacement);
  const decisionsBeforeEmpty = (await calls()).filter(row => row.method === 'approvals.decide').length;
  await emptyApproval.locator('[data-testid="approval-approve"]').click();
  await page.waitForFunction(count => window.__setupEditCalls.filter(row => row.method === 'approvals.decide' && row.ok).length > count, decisionsBeforeEmpty);
  await waitForSource(target, emptyReplacement, 'empty-document approval did not write its exact reviewed source');
  const emptyDrawer = await openSkill();
  const emptyReader = await showReaderSource(emptyDrawer);
  assert.equal(await emptyReader.locator('.reading-file-source code').textContent(), emptyReplacement);
  await page.locator('#detail-drawer:not(.hidden) .btn-setup-undo').click();
  await page.locator('#btn-setup-confirm-undo').click();
  await waitForSource(target, '', 'empty-document undo did not restore zero bytes');
  const emptyUndoneDrawer = await openSkill();
  await currentReader(emptyUndoneDrawer).locator('.reading-empty').waitFor({state: 'visible'});
  const emptyUndoneReader = await showReaderSource(emptyUndoneDrawer);
  assert.equal(await emptyUndoneReader.locator('.reading-file-source code').textContent(), '');
  result.checks.push({name: 'empty-source-to-nonempty-ui-approval-and-undo', passed: true, replacementHash: sha(emptyReplacement)});

  // Establish a nonempty external fixture baseline, then use only the UI to
  // clear it. This is deliberately the inverse of the empty-source case.
  await writeFile(target, emptyReplacement, 'utf8');
  await scanSetup();
  const clearArea = await openEditor();
  assert.equal(await clearArea.inputValue(), emptyReplacement);
  await page.setViewportSize({width: 900, height: 700});
  const geometry = await page.evaluate(() => {
    const rect = element => { const r = element.getBoundingClientRect(); return {left:r.left, right:r.right, top:r.top, bottom:r.bottom, width:r.width, height:r.height}; };
    const modal = document.getElementById('modal-dialog');
    const textarea = document.getElementById('setup-editor-source');
    const footerButtons = [...document.querySelectorAll('#modal-footer button')].map(button => {
      const bounds = rect(button);
      const visible = button.getClientRects().length > 0;
      const hit = visible ? document.elementFromPoint(bounds.left + bounds.width / 2, bounds.top + bounds.height / 2) : null;
      return {id:button.id, visible, rect:bounds, centerHit: hit ? {tag:hit.tagName, id:hit.id, className:String(hit.className || '')} : null, centerHitsButton: Boolean(hit && (hit === button || button.contains(hit)))};
    });
    return {width:innerWidth, height:innerHeight, scrollWidth:document.body.scrollWidth, modal:rect(modal), textarea:rect(textarea), footerButtons};
  });
  assert.equal(geometry.footerButtons.length, 4, 'setup editor must retain its four footer controls.');
  assert.ok(geometry.scrollWidth <= geometry.width, 'editor must not create horizontal page overflow at 900px.');
  for (const [label, rect] of [['modal', geometry.modal], ['textarea', geometry.textarea]]) {
    assert.ok(rect.left >= 0 && rect.right <= geometry.width && rect.top >= 0 && rect.bottom <= geometry.height, `${label} must remain in the 900px viewport.`);
  }
  for (const button of geometry.footerButtons.filter(button => button.visible)) {
    assert.ok(button.rect.left >= 0 && button.rect.right <= geometry.width && button.rect.top >= 0 && button.rect.bottom <= geometry.height, `${button.id} must remain reachable in the 900px viewport.`);
    assert.ok(button.centerHitsButton, `${button.id} center must hit its button or a child, not an overlay.`);
  }
  await page.screenshot({path: output + '/setup-editor-900px-write.png'});
  result.checks.push({name: 'open-setup-editor-has-no-900px-horizontal-overflow-and-reachable-footer', passed: true, geometry});
  await clearArea.fill('');
  await page.locator('[data-edit-view="diff"]').click();
  const clearDiff = page.locator('#setup-editor-diff [data-review-complete="true"]');
  await clearDiff.waitFor({state: 'visible'});
  assert.equal(await clearDiff.locator('.reading-change-removed code').textContent(), emptyReplacement);
  assert.equal(await clearDiff.locator('.reading-change-added').count(), 0);
  await page.screenshot({path: output + '/setup-editor-900px-diff.png'});
  await page.locator('#btn-setup-request').click();
  await page.locator('.nav-link[data-page="inbox"].active').waitFor({state: 'visible'});
  const clearApproval = await pendingSetupApproval();
  await clearApproval.waitFor({state: 'visible'});
  const decisionsBeforeClear = (await calls()).filter(row => row.method === 'approvals.decide' && row.ok).length;
  await clearApproval.locator('[data-testid="approval-approve"]').click();
  await page.waitForFunction(count => window.__setupEditCalls.filter(row => row.method === 'approvals.decide' && row.ok).length > count, decisionsBeforeClear);
  await waitForSource(target, '', 'clearing a nonempty document through the UI did not approve exact zero bytes');
  const clearedDrawer = await openSkill();
  await currentReader(clearedDrawer).locator('.reading-empty').waitFor({state: 'visible'});
  const clearedReader = await showReaderSource(clearedDrawer);
  assert.equal(await clearedReader.locator('.reading-file-source code').textContent(), '');
  result.checks.push({name: 'nonempty-document-ui-clear-complete-diff-and-zero-byte-approval', passed: true, geometry});

  assert.equal(await page.evaluate(() => window.__setupEditListeners.size), 0, 'closing, discarding and submitting editors must release their request-settlement listeners.');
  result.checks.push({name: 'closed-and-discarded-editors-release-request-settlement-listeners', passed: true});

} catch (error) {
  result.errors.push({type: 'assertion', message: error.stack || String(error)});
  process.exitCode = 1;
} finally {
  try { await writeFile(target, initial, 'utf8'); result.restoredFixtureSource = (await readFile(target, 'utf8')) === initial; }
  catch (error) { result.errors.push({type: 'fixture-restore', message: error.message}); process.exitCode = 1; }
  if (browser) { await browser.close(); result.browserClosed = true; }
  result.sourceAfter = await hashes();
  result.sourceUnchanged = JSON.stringify(result.sourceBefore) === JSON.stringify(result.sourceAfter);
  result.passed = result.checks.length === EXPECTED_CHECKS && result.errors.length === 0 && result.sourceUnchanged && result.restoredFixtureSource && result.browserClosed;
  await writeFile(output + '/results.json', JSON.stringify(result, null, 2));
  console.log(JSON.stringify({passed: result.passed, checks: result.checks.length, errors: result.errors, output}));
  if (!result.passed) process.exitCode = 1;
}
