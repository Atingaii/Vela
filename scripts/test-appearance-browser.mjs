#!/usr/bin/env node
// Real isolated RPC acceptance. Delays deliver actual responses; one explicit
// injected transport failure happens before persistence to test UI rollback.
import playwright from '../.task-tmp/ui-browser-tools/node_modules/playwright/index.js';
import assert from 'node:assert/strict';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {resolve, relative, sep} from 'node:path';
import {createHash} from 'node:crypto';
const [url, output, fixturePath, uiRoot] = process.argv.slice(2);
if (!url?.startsWith('http://127.0.0.1:') || !output?.startsWith('output/playwright/') || !fixturePath || !uiRoot?.startsWith('.task-tmp/')) throw Error('Pass isolated URL, new evidence directory, fixture.json, and frozen UI directory.');
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const base = resolve(fixturePath, '..');
assert.ok(fixture.synthetic && base.startsWith(resolve('.task-tmp') + sep) && resolve(fixture.home) === resolve(base, 'store'));
await mkdir(output, {recursive:false});
const filenames = ['app.js','app.css','reading.css','appearance.js','index.html','i18n.js','content.js'];
const hashes = async () => Object.fromEntries(await Promise.all(filenames.map(async name => [name, createHash('sha256').update(await readFile(resolve(uiRoot,name))).digest('hex')])));
const result = {synthetic:true,native:false,fixture:relative(process.cwd(),base),sourceBefore:await hashes(),checks:[],errors:[],complete:false};
let browser;
try {
 browser = await playwright.chromium.launch({headless:true,executablePath:process.env.VELA_BROWSER_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
 const context = await browser.newContext({viewport:{width:1250,height:800}});
 const page = await context.newPage();
 page.on('pageerror',e=>result.errors.push(e.message));
 await page.goto(url);
 await page.locator('.session-card').first().waitFor();
 const settings = async () => page.evaluate(() => window.vela.call('settings.get',{}));
 const goSettings = async () => {
   const menu = page.locator('.companion-nav > details');
   if (!(await page.locator('.nav-link[data-page="settings"]').isVisible())) await menu.locator('summary').click();
   await page.locator('.nav-link[data-page="settings"]:visible,.companion-link[data-page="settings"]:visible').first().click();
   await page.locator('[data-settings-category="general"]').click();
   await page.locator('[data-appearance-theme="dark"]').waitFor();
 };
 await goSettings();
 const initial = await settings();
 await page.evaluate(() => {
   const original = window.vela.call;
   window.__appearanceTest = {calls:[],reads:[],inFlight:0,maxInFlight:0,hold:false,holdRead:null,fail:false};
   window.vela.call = async (method, params={}) => {
     const test=window.__appearanceTest;
     if(method==='dashboard.get' || method==='settings.get') {
       const confirmed=await original(method,params);test.reads.push({method,confirmed});
       const hold=test.holdRead;
       if(hold?.method===method && !hold.held){hold.held=true;hold.confirmed=confirmed;await new Promise(r=>hold.release=r);hold.released=true;}
       return confirmed;
     }
     if(method!=='settings.save' || !['theme','density','zoomPercent'].some(k=>Object.hasOwn(params,k))) return original(method,params);
     test.inFlight++;test.maxInFlight=Math.max(test.maxInFlight,test.inFlight);
     try {
       if(test.fail){test.fail=false;throw Error('Injected appearance transport failure before write');}
       const confirmed=await original(method,params);test.calls.push({params,confirmed});
       if(test.hold){test.hold=false;test.held=true;await new Promise(r=>test.release=r);test.held=false;}
       return confirmed;
     }finally{test.inFlight--;}
   };
 });
 await page.locator('[data-appearance-theme="dark"]').click();
 await page.waitForFunction(()=>document.documentElement.dataset.theme==='dark' && window.__appearanceTest.calls.length>=1 && window.__appearanceTest.inFlight===0);
 assert.equal((await settings()).theme,'dark');
 const dark = await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--bg-app').trim());
 assert.match(dark,/^#(?:121214|[0-3][0-9a-f]{5})$/i,'Dark tokens must actually resolve to a dark surface.');
 await page.screenshot({animations: 'disabled', path:resolve(output,'appearance-dark-workspace.png')});
 result.checks.push('Explicit dark theme renders and persists through real settings.save');
 const radio=page.locator('[data-appearance-theme="dark"]');
 await radio.focus();await radio.press('Home');
 await page.waitForFunction(()=>window.VelaAppearance.getConfirmed().theme==='system' && window.__appearanceTest.inFlight===0);
 await page.emulateMedia({colorScheme:'dark'});
 await page.waitForFunction(()=>document.documentElement.dataset.theme==='dark');
 await page.emulateMedia({colorScheme:'light'});
 await page.waitForFunction(()=>document.documentElement.dataset.theme==='light');
 assert.equal(await page.locator('#appearance-theme-group [tabindex="0"]').count(),1);
 result.checks.push('System appearance follows matchMedia and radio group keyboard navigation');
 await page.evaluate(()=>window.__appearanceTest.hold=true);
 await page.locator('[data-appearance-density="compact"]').click();
 await page.waitForFunction(()=>window.__appearanceTest.held);
 await page.locator('[data-appearance-zoom="125"]').click();
 await page.locator('[data-appearance-theme="dark"]').click();
 await page.evaluate(()=>window.__appearanceTest.release());
 await page.waitForFunction(()=>window.__appearanceTest.inFlight===0 && document.documentElement.dataset.theme==='dark' && window.VelaAppearance.getConfirmed().zoomPercent===125);
 const serial=await settings();
 assert.equal(serial.theme,'dark');assert.equal(serial.density,'compact');assert.equal(serial.zoomPercent,125);
 assert.equal(await page.evaluate(()=>window.__appearanceTest.maxInFlight),1);
 result.checks.push('Rapid combined changes serialize actual writes and preserve final selection');
 await page.evaluate(()=>window.__appearanceTest.fail=true);
 await page.locator('[data-appearance-theme="light"]').click();
 await page.waitForFunction(()=>document.documentElement.dataset.theme==='dark' && document.querySelector('[data-appearance-theme="dark"]').getAttribute('aria-checked')==='true');
 assert.equal((await settings()).theme,'dark');
 result.checks.push('Explicit failed transport rolls back DOM, radio state, and leaves persisted settings unchanged');
 // A dirty unrelated setting must survive an appearance write without saving it.
 await page.locator('[data-settings-category="notifications"]').click();
 const notification = page.locator('#setting-notifications');
 await notification.waitFor();const priorChecked=await notification.isChecked();await notification.setChecked(!priorChecked);
 await page.locator('[data-settings-category="general"]').click();
 await page.locator('[data-appearance-zoom="110"]').click();
 await page.waitForFunction(()=>window.VelaAppearance.getConfirmed().zoomPercent===110 && window.__appearanceTest.inFlight===0);
 assert.equal((await settings()).notifications,initial.notifications);
 await page.locator('[data-settings-category="notifications"]').click();
 assert.equal(await notification.isChecked(),!priorChecked);
 result.checks.push('Unrelated notification draft stays unsaved and remains in the UI after appearance save');

 // Hold a real dashboard response that was read before the next save. Its
 // settings are real but stale by delivery time, so this exercises the
 // renderer's preferences epoch instead of manufacturing an old response.
 await page.locator('[data-settings-category="general"]').click();
 await page.locator('[data-appearance-zoom="100"]').click();
 await page.waitForFunction(()=>window.VelaAppearance.getConfirmed().zoomPercent===100 && window.__appearanceTest.inFlight===0);
 const typographyBaseline = await page.evaluate(()=>({
   uiScale:document.documentElement.style.getPropertyValue('--ui-scale').trim(),
   rootInlineFont:document.documentElement.style.fontSize,
   rootComputedFont:getComputedStyle(document.documentElement).fontSize,
   bodyFont:getComputedStyle(document.body).fontSize,
   previewTitleFont:getComputedStyle(document.querySelector('.appearance-preview-card h4')).fontSize
 }));
 assert.equal(typographyBaseline.uiScale,'1');
 const beforeDelayedDashboard = await settings();
 await page.evaluate(()=>{
   window.__appearanceTest.holdRead={method:'dashboard.get'};
   window.dispatchEvent(new CustomEvent('vela:refresh',{detail:{source:'appearance-epoch-test'}}));
 });
 await page.waitForFunction(()=>window.__appearanceTest.holdRead?.held===true);
 const delayedSettings = await page.evaluate(()=>window.__appearanceTest.holdRead.confirmed?.settings);
 assert.equal(delayedSettings.zoomPercent,beforeDelayedDashboard.zoomPercent,'Held dashboard response must contain the real pre-save settings.');
 await page.locator('[data-appearance-zoom="125"]').click();
 await page.waitForFunction(()=>window.VelaAppearance.getConfirmed().zoomPercent===125 && window.__appearanceTest.inFlight===0);
 await page.evaluate(()=>window.__appearanceTest.holdRead.release());
 await page.waitForFunction(()=>window.__appearanceTest.holdRead.released===true && document.documentElement.style.getPropertyValue('--ui-scale').trim()==='1.25');
 const afterDelayedDashboard = await settings();
 const delayedScale = await page.evaluate(()=>({
   uiScale:document.documentElement.style.getPropertyValue('--ui-scale').trim(),
   rootInlineFont:document.documentElement.style.fontSize,
   rootComputedFont:getComputedStyle(document.documentElement).fontSize,
   bodyFont:getComputedStyle(document.body).fontSize,
   previewTitleFont:getComputedStyle(document.querySelector('.appearance-preview-card h4')).fontSize
 }));
 assert.equal(afterDelayedDashboard.zoomPercent,125);
 assert.equal(await page.evaluate(()=>window.VelaAppearance.getConfirmed().zoomPercent),125);
 assert.equal(delayedScale.uiScale,'1.25');
 assert.equal(delayedScale.rootInlineFont,typographyBaseline.rootInlineFont,'Appearance JS must not write documentElement.style.fontSize.');
 assert.ok(Math.abs(parseFloat(delayedScale.bodyFont)/parseFloat(typographyBaseline.bodyFont)-1.25)<0.01,JSON.stringify({typographyBaseline,delayedScale}));
 assert.ok(Math.abs(parseFloat(delayedScale.previewTitleFont)/parseFloat(typographyBaseline.previewTitleFont)-1.25)<0.01,JSON.stringify({typographyBaseline,delayedScale}));
 result.checks.push('A delayed real pre-save dashboard response cannot roll back confirmed appearance preferences or CSS-token scale');

 // A first mount can disappear before its confirmed RPC reaches the renderer.
 // The second mount must enqueue behind that real write. Its zoom-only choice
 // must retain the first, already persisted density rather than revive stale UI state.
 const remountCallsBefore = await page.evaluate(()=>window.__appearanceTest.calls.length);
 const remountExpectedDensity = 'standard';
 await page.evaluate(()=>window.__appearanceTest.hold=true);
 await page.locator('[data-appearance-density="standard"]').click();
 await page.waitForFunction(()=>window.__appearanceTest.held===true);
 const firstRemountWrite = await settings();
 assert.equal(firstRemountWrite.density,remountExpectedDensity,'The held response must still represent a real persisted first-mount write.');
 await page.locator('.nav-link[data-page="agents"]:visible,.companion-link[data-page="agents"]:visible').first().click();
 await goSettings();
 await page.locator('[data-appearance-zoom="110"]').click();
 await page.evaluate(()=>window.__appearanceTest.release());
 await page.waitForFunction(expectedDensity=>window.__appearanceTest.inFlight===0 && window.VelaAppearance.getConfirmed().density===expectedDensity && window.VelaAppearance.getConfirmed().zoomPercent===110,remountExpectedDensity);
 const remounted = await settings();
 const remountCalls = await page.evaluate(before=>window.__appearanceTest.calls.slice(before),remountCallsBefore);
 assert.ok(remountCalls.length>=2,'Both mounts must reach the real settings.save bridge.');
 assert.equal(remountCalls[0].params.density,remountExpectedDensity);
 assert.equal(remountCalls[0].confirmed.density,remountExpectedDensity);
 const remountFinalParams = remountCalls.at(-1).params;
 if (Object.hasOwn(remountFinalParams,'density')) assert.equal(remountFinalParams.density,remountExpectedDensity,'If sent, density on a zoom-only remount action must retain the latest real confirmed value.');
 assert.equal(remountFinalParams.zoomPercent,110);
 assert.equal(remounted.theme,'dark');assert.equal(remounted.density,remountExpectedDensity);assert.equal(remounted.zoomPercent,110);
 assert.equal(await page.evaluate(()=>window.__appearanceTest.maxInFlight),1);
 await page.locator('[data-settings-category="notifications"]').click();
 assert.equal(await page.locator('#setting-notifications').isChecked(),!priorChecked,'Settings remount must retain the unrelated unsaved draft.');
 result.checks.push('Cross-Settings-remount appearance writes serialize real RPCs and retain unrelated drafts');
 await page.locator('[data-settings-category="general"]').click();
 await page.setViewportSize({width:440,height:760});
 await page.locator('[data-appearance-zoom="150"]').click();
 await page.waitForFunction(()=>window.VelaAppearance.getConfirmed().zoomPercent===150 && window.__appearanceTest.inFlight===0);
 const geometry=await page.evaluate(()=>({
   width:innerWidth,
   scroll:document.documentElement.scrollWidth,
   uiScale:document.documentElement.style.getPropertyValue('--ui-scale').trim(),
   rootInlineFont:document.documentElement.style.fontSize,
   rootComputedFont:getComputedStyle(document.documentElement).fontSize,
   body:getComputedStyle(document.body).fontSize,
   previewTitle:getComputedStyle(document.querySelector('.appearance-preview-card h4')).fontSize,
   shell:getComputedStyle(document.documentElement).getPropertyValue('--shell-height')
 }));
 assert.ok(geometry.scroll<=geometry.width+1,JSON.stringify(geometry));
 assert.equal(geometry.uiScale,'1.5');
 assert.equal(geometry.rootInlineFont,typographyBaseline.rootInlineFont,'Appearance JS must not write documentElement.style.fontSize at 150%.');
 assert.ok(Math.abs(parseFloat(geometry.body)/parseFloat(typographyBaseline.bodyFont)-1.5)<0.01,JSON.stringify({typographyBaseline,geometry}));
 assert.ok(Math.abs(parseFloat(geometry.previewTitle)/parseFloat(typographyBaseline.previewTitleFont)-1.5)<0.01,JSON.stringify({typographyBaseline,geometry}));
 await page.screenshot({animations: 'disabled', path:resolve(output,'appearance-dark-companion-150.png')});
 result.checks.push({name:'Narrow companion at 150% has scaled body text and no document overflow',geometry});
 await page.reload();await page.locator('.session-card').first().waitFor();await goSettings();
 const reloaded=await settings();assert.equal(reloaded.theme,'dark');assert.equal(reloaded.density,remountExpectedDensity);assert.equal(reloaded.zoomPercent,150);
 assert.equal(await page.locator('[data-appearance-zoom="150"]').getAttribute('aria-checked'),'true');
 result.checks.push('Full reload restores persisted appearance controls and styling');
 // Restore the owned fixture to standard baseline for the next serial suite.
 await page.evaluate(initial=>window.vela.call('settings.save',{theme:initial.theme,density:initial.density,zoomPercent:initial.zoomPercent}),initial);
 assert.equal(result.errors.length,0,JSON.stringify(result.errors));result.complete=true;
} catch(error){result.errors.push({message:error.message,stack:error.stack});process.exitCode=1;}
finally{
 if(browser){await browser.close();result.browserClosed=true;}
 result.sourceAfter=await hashes();result.sourceUnchanged=JSON.stringify(result.sourceBefore)===JSON.stringify(result.sourceAfter);
 if(!result.sourceUnchanged){process.exitCode=1;result.complete=false;}
 await writeFile(resolve(output,'results.json'),JSON.stringify(result,null,2)+'\n');
 console.log(JSON.stringify({complete:result.complete,checks:result.checks.length,errors:result.errors}));
}
