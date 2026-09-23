import {test, expect} from '@playwright/test';

async function bridge(page){
  await page.addInitScript(() => {
    const listeners = {};
    const now = Date.now();
    const ids = ['claude','codex','cursor','gemini','glm','grok'];
    const reading = (id, stamp) => ({status:'ok',fetched_at:stamp,windows:[{id:'session',label:'Session',used:.2,has_fraction:true,resets_at:stamp+3600000}]});
    window.emitNotch = (name,payload) => listeners[name]?.forEach(callback => callback({payload}));
    window.notchFixture = {ids,rows:ids.map(id => ({id,name:id,headline:'session',guidance:'',enabled:true,snap:reading(id,now+1000)}))};
    window.__TAURI__ = {core:{invoke:async command => {
      if(command==='get_providers')return window.notchFixture.rows;
      if(command==='get_notch_slots')return ids.map(provider => ({provider}));
      if(command==='get_disabled_providers'||command==='get_activity')return [];
      if(command==='get_glyphs')return {};
      if(command==='get_usage')return reading('claude',now);
      if(command==='get_state')return {sessions:[],agg:'idle',lang_resolved:'en'};
      if(command==='get_codex'||command==='get_cursor'||command==='get_antigravity'||command==='get_glm'||command==='get_grok')return reading(command,now);
      if(command==='get_appearance')return {};
      if(command==='get_ui_flags')return {notch_visible:true,notch_on_hover:false};
      if(command==='get_notch_edge')return 'right';
      if(command==='get_move_handle')return false;
      return null;
    }},event:{listen:async(name,callback) => { (listeners[name]??=[]).push(callback);return () => {};}}};
  });
}

test('默认账户 Reading 与快速 getter 只生成一个环，关闭账户立即移除', async ({page}) => {
  await bridge(page);
  await page.goto('/notch.html');
  await expect.poll(() => page.locator('.cell').count()).toBe(6);
  expect(await page.locator('.cell').evaluateAll(cells => cells.map(cell => cell.dataset.p)))
    .toEqual(['claude','codex','cursor','gemini','glm','grok']);
  await page.evaluate(()=>{window.keptCursor=document.querySelector('.cell[data-p="cursor"]');});
  await page.evaluate(() => {
    const rows = notchFixture.rows.map(row => row.id==='codex'?{...row,enabled:false}:row);
    emitNotch('providers', rows);
  });
  await expect(page.locator('.cell[data-p="codex"]')).toHaveCount(0);
  await expect(page.locator('.cell')).toHaveCount(5);
  expect(await page.evaluate(()=>document.querySelector('.cell[data-p="cursor"]')===keptCursor)).toBe(true);
  await page.evaluate(() => {
    emitNotch('codex',{status:'ok',fetched_at:Date.now()+2000,windows:[{id:'primary',used:.7,has_fraction:true}]});
    emitNotch('providers',notchFixture.rows);
  });
  await expect(page.locator('.cell[data-p="codex"]')).toHaveCount(1);
  await expect(page.locator('.cell')).toHaveCount(6);
  expect(await page.evaluate(()=>document.querySelector('.cell[data-p="cursor"]')===keptCursor)).toBe(true);
});

test('同一活动快照保留旋转相位，状态切换销毁旧弧；读数按弹簧扫动',async({page})=>{
  await bridge(page);
  await page.goto('/notch.html');
  await expect(page.locator('.cell')).toHaveCount(6);
  const activity={id:'codex-turn',provider:'codex',state:'busy',name:'Working',detail:'',waiting_for:null,since:Date.now(),queued:0};
  await page.evaluate(row=>emitNotch('activity',[row]),activity);
  await expect(page.locator('.cell[data-p="codex"] .arc-spin')).toHaveCount(1);
  expect(await page.locator('.cell[data-p="codex"] .arc-spin').evaluate(el=>[getComputedStyle(el).animationDuration,getComputedStyle(el).animationTimingFunction])).toEqual(['1.1s','linear']);
  await page.evaluate(()=>{window.firstSpinner=document.querySelector('.cell[data-p="codex"] .arc-spin');});
  await expect.poll(()=>page.evaluate(()=>firstSpinner?.getAnimations()[0]?.currentTime||0)).toBeGreaterThan(0);
  const before=await page.evaluate(()=>firstSpinner.getAnimations()[0].currentTime);
  await page.evaluate(row=>{emitNotch('activity',[row]);emitNotch('providers',notchFixture.rows);},activity);
  expect(await page.evaluate(()=>document.querySelector('.cell[data-p="codex"] .arc-spin')===firstSpinner)).toBe(true);
  await expect.poll(()=>page.evaluate(()=>firstSpinner.getAnimations()[0].currentTime)).toBeGreaterThan(before);
  await page.evaluate(()=>setFolded(true));
  await expect(page.locator('.cell[data-p="codex"] .arc-spin')).toHaveCount(0);
  await page.evaluate(()=>setFolded(false));
  await expect(page.locator('.cell[data-p="codex"] .arc-spin')).toHaveCount(1);
  expect(await page.evaluate(()=>document.querySelector('.cell[data-p="codex"] .arc-spin')===firstSpinner)).toBe(false);
  await page.evaluate(row=>{emitNotch('notch_landing',null);emitNotch('activity',[row]);},activity);
  await expect(page.locator('.cell[data-p="codex"] .arc-spin')).toHaveCount(0);
  await page.evaluate(()=>emitNotch('notch_reveal',null));
  await expect(page.locator('.cell[data-p="codex"] .arc-spin')).toHaveCount(1);
  await page.evaluate(()=>{
    const rows=notchFixture.rows.map(row=>row.id==='codex'?{...row,snap:{...row.snap,fetched_at:Date.now()+5000,windows:[{id:'session',used:.8,has_fraction:true}]}}:row);
    emitNotch('providers',rows);
  });
  await expect(page.locator('.cell[data-p="codex"] .pct')).toHaveText('80%');
  const dash=()=>page.evaluate(()=>Number(document.querySelector('.cell[data-p="codex"] svg.reading circle')?.getAttribute('stroke-dasharray')?.split(' ')[0]));
  const initial=await dash();
  await expect.poll(dash).toBeGreaterThan(initial);
  await page.evaluate(row=>emitNotch('activity',[{...row,state:'waiting'}]),activity);
  await expect(page.locator('.cell[data-p="codex"] .arc-spin')).toHaveCount(0);
  await expect(page.locator('.cell[data-p="codex"] .arc-pulse')).toHaveCount(1);
  expect(await page.locator('.cell[data-p="codex"] .arc-pulse').evaluate(el=>[getComputedStyle(el).animationDuration,getComputedStyle(el).animationDirection])).toEqual(['0.9s','alternate']);
  await page.evaluate(()=>emitNotch('native_notch_surface',{glass_available:false,effective_surface_style:'solid',reduce_transparency:true}));
  await expect(page.locator('body')).toHaveClass(/reduce-transparency/);
  expect(await page.locator('.cell[data-p="codex"] .arc-pulse').evaluate(el=>getComputedStyle(el).getPropertyValue('--activity-pulse-min').trim())).toBe('.65');
  await page.evaluate(()=>emitNotch('native_notch_surface',{glass_available:false,effective_surface_style:'solid',reduce_transparency:false}));
  await expect(page.locator('body')).not.toHaveClass(/reduce-transparency/);
  await page.evaluate(()=>emitNotch('activity',[]));
  await expect(page.locator('.cell[data-p="codex"] .arc-pulse')).toHaveCount(0);
});

test('卡片沿边弹簧进出，折叠时手柄按 200 ms ease-in 归并',async({page})=>{
  await bridge(page);
  await page.goto('/notch.html');
  await expect(page.locator('.cell')).toHaveCount(6);
  await page.evaluate(()=>{hoverId='codex';showCard();});
  await expect(page.locator('#card')).toHaveClass(/show/);
  await expect.poll(()=>page.locator('#card').evaluate(el=>Number(el.style.opacity))).toBeGreaterThan(.95);
  await page.evaluate(()=>hideCard());
  await expect(page.locator('#card')).not.toHaveClass(/show/);
  await page.evaluate(()=>setFolded(true));
  await expect.poll(()=>page.locator('#orb').evaluate(el=>el.style.opacity)).toBe('0');
  expect(await page.locator('#orb').evaluate(el=>Number(getComputedStyle(el).transform.match(/matrix\(([^,]+)/)?.[1]))).toBeCloseTo(121/76,2);
  await page.evaluate(()=>setFolded(false));
  await expect.poll(()=>page.locator('#orb').evaluate(el=>Number(el.style.opacity))).toBeGreaterThan(.95);
});
