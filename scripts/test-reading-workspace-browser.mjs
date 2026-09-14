#!/usr/bin/env node
// Real-helper browser checks for the reading layout and primary product flows.
import playwright from '../.task-tmp/ui-browser-tools/node_modules/playwright/index.js';
const {chromium} = playwright;
import assert from 'node:assert/strict';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const [url, output, uiDirectory] = process.argv.slice(2);
if (!url?.startsWith('http://127.0.0.1:') || !output?.startsWith('output/playwright/')) throw Error('Use a local synthetic test bridge and new output/playwright directory.');
const uiRoot = uiDirectory || 'Sources/VelaApp/Resources/UI';
if (uiDirectory && (!uiDirectory.startsWith('.task-tmp/') || uiDirectory.includes('..'))) throw Error('Use an owned frozen UI directory below .task-tmp.');
await mkdir(output, {recursive:false});
const files=['app.js','app.css','content.js','reading.css','i18n.js','index.html'];
const hash=async()=>Object.fromEntries(await Promise.all(files.map(async n=>[n,createHash('sha256').update(await readFile(uiRoot+'/'+n)).digest('hex')])));
const result={synthetic:true,native:false,sourceBefore:await hash(),checks:[],errors:[]};
const browser=await chromium.launch({headless:true,executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try {
 const context=await browser.newContext({viewport:{width:1250,height:800}});await context.grantPermissions(['clipboard-read','clipboard-write']);
 const page=await context.newPage();page.on('pageerror',e=>result.errors.push(e.message));await page.goto(url);await page.locator('.session-card').first().waitFor();
 await page.screenshot({path:output+'/sessions.png'});
 await page.locator('.session-title-btn').filter({hasText:'Prepare the verification handoff'}).click();await page.locator('.session-message-card').first().waitFor();
 let layout=await page.evaluate(()=>{let sidebar=document.querySelector('.sidebar').getBoundingClientRect(),drawer=document.querySelector('#detail-drawer').getBoundingClientRect(),main=document.querySelector('#main-content');return {sidebarRight:sidebar.right,drawerLeft:drawer.left,drawerWidth:drawer.width,hidden:getComputedStyle(main).visibility,inert:main.inert,overflow:document.body.scrollWidth>innerWidth};});
 assert.equal(layout.inert,true);assert.equal(layout.hidden,'hidden');assert.ok(Math.abs(layout.drawerLeft-layout.sidebarRight)<2);assert.ok(layout.drawerWidth>=900);assert.equal(layout.overflow,false);assert.ok(await page.locator('.session-message-card .reading-code .token').count()>0);
 result.checks.push({name:'readable-session-workspace',passed:true,layout});await page.screenshot({path:output+'/session-reading.png'});
 await page.locator('#btn-close-drawer').click();assert.equal(await page.locator('#main-content').getAttribute('inert'),null);
 await page.locator('[data-page="memory"]').click();await page.locator('.memory-card').first().waitFor();
 assert.equal(await page.locator('#btn-export-memory-archive').isVisible(),false);assert.equal(await page.locator('#btn-new-memory').isVisible(),true);
 await page.locator('.memory-primary-actions .action-menu > summary').click();assert.equal(await page.locator('#btn-export-memory-archive').isVisible(),true);
 await page.keyboard.press('Escape');assert.equal(await page.locator('#btn-export-memory-archive').isVisible(),false);
 const firstMemory=page.locator('.memory-card').first();await firstMemory.locator('.btn-mem-view').click();await page.locator('#detail-drawer:not(.hidden) .reading-file[data-view="preview"]').waitFor();await page.locator('#btn-close-drawer').click();
 await firstMemory.locator('.action-menu > summary').click();assert.equal(await firstMemory.locator('.btn-mem-edit').isVisible(),true);await page.keyboard.press('Escape');
 await page.screenshot({path:output+'/memory.png'});result.checks.push({name:'memory-title-and-progressive-actions',passed:true,drawerOpenedFromTitle:true});
 await page.locator('[data-page="inbox"]').click();const card=page.locator('.approval-card').filter({hasText:'Write the reviewed note'});await card.locator('.reading-prose h1').waitFor();assert.equal(await card.locator('.reading-prose h1').innerText(),'Verification');
 await card.locator('.reading-source').click();assert.equal(await card.locator('.reading-file-source code').textContent(),'# Verification\n\nThe focused parser checks passed.\n');await card.locator('.reading-copy').click();assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),'# Verification\n\nThe focused parser checks passed.\n');await card.locator('.reading-preview').click();
 await card.scrollIntoViewIfNeeded();await page.screenshot({path:output+'/approval.png'});result.checks.push({name:'actual-approval-markdown-source-copy',passed:true});
 await page.locator('[data-page="setup"]').click();await page.locator('[data-setuptab="skills"]').click();
 const skill=page.locator('article.workspace-row.asset-row[data-testid="asset-row"]').filter({has:page.locator('.btn-preview-artifact')}).first();
 await skill.locator('.row-title.btn-preview-artifact').click();const setupReader=page.locator('#detail-drawer:not(.hidden) .reading-file');await page.locator('#detail-drawer:not(.hidden) .reading-file[data-view="preview"]').waitFor();
 assert.equal(await setupReader.locator('.reading-prose').isVisible(),true);assert.match(await setupReader.locator('.reading-prose').innerText(),/Inspect the diff and the assertion that covers invalid input\./);
 const metadata=setupReader.locator('details.reading-frontmatter');assert.equal(await metadata.count(),1);assert.equal(await metadata.evaluate(e=>e.open),false);await metadata.locator('summary').click();assert.match(await metadata.innerText(),/name: review-request-boundary/);
 assert.equal(await setupReader.locator('img,svg,[onclick],[onerror]').count(),0);
 const expectedSkill='---\nname: review-request-boundary\ndescription: Review request validation changes.\n---\n\nInspect the diff and the assertion that covers invalid input.\n';
 await setupReader.locator('.reading-source').click();assert.equal(await setupReader.locator('.reading-file-source code').textContent(),expectedSkill);await setupReader.locator('.reading-copy').click();assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),expectedSkill);await setupReader.locator('.reading-preview').click();
 await page.screenshot({path:output+'/setup-skill-reading.png'});result.checks.push({name:'actual-setup-skill-markdown-metadata-source-copy-inert-html',passed:true,sourceBytes:expectedSkill.length});
 await page.setViewportSize({width:900,height:620});await page.locator('[data-page="memory"]').click();
 const geometry=await page.evaluate(()=>{let es=[...document.querySelectorAll('.memory-filter-btn,.memory-primary-actions > button,.memory-primary-actions > details')].map(e=>{let r=e.getBoundingClientRect();return {x:r.x,right:r.right,width:r.width};});return {width:innerWidth,body:document.body.scrollWidth,items:es};});assert.ok(geometry.body<=geometry.width);for(const r of geometry.items)assert.ok(r.x>=0&&r.right<=geometry.width);
 await page.screenshot({path:output+'/memory-900.png'});result.checks.push({name:'900px-memory-layout',passed:true,geometry});
 await page.setViewportSize({width:1250,height:800});await page.locator('[data-page="settings"]').click();const general=page.locator('[data-settings-category="general"]');await general.click();await page.locator('[data-settings-panel="general"]:not([hidden]) #setting-locale').waitFor();await page.locator('#setting-locale').selectOption('en');await page.locator('[data-page="memory"]').click();assert.equal(await page.locator('#page-container').evaluate(e=>e.scrollTop),0);assert.ok(await page.locator('h1').isVisible());await page.screenshot({path:output+'/memory-en.png'});assert.match(await page.locator('h1').innerText(),/Memory/);result.checks.push({name:'english-memory-layout',passed:true,settingsCategory:'general'});
} catch(e) {result.errors.push(e.stack||String(e));process.exitCode=1;} finally {await browser.close();result.sourceAfter=await hash();result.sourceUnchanged=JSON.stringify(result.sourceBefore)===JSON.stringify(result.sourceAfter);result.passed=result.checks.length===6&&result.errors.length===0&&result.sourceUnchanged;await writeFile(output+'/results.json',JSON.stringify(result,null,2));console.log(JSON.stringify({passed:result.passed,checks:result.checks.length,errors:result.errors,output}));if(!result.passed)process.exitCode=1;}
