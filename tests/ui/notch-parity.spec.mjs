import {test,expect} from '@playwright/test';

async function notchBridge(page){
  await page.addInitScript(()=>{
    const listeners={};window.notchCalls=[];
    window.emitNotch=(name,payload)=>listeners[name]?.forEach(callback=>callback({payload}));
    const now=Date.now();
    const sessions=Array.from({length:10},(_,i)=>({id:`session-${i}`,title:`Session ${i}`,state:'running',last:'Working',prompt:'A request',started:now-i*1000}));
    const usage={status:'ok',fetched_at:now,windows:[{id:'session',label:'Session',used:.25,resets_at:now+3600000}]};
    const slots=['claude','codex','cursor','gemini','glm','grok'].map(provider=>({provider}));
    window.__TAURI__={core:{invoke:async(cmd,args)=>{
      window.notchCalls.push({cmd,args});
      if(cmd==='get_notch_slots')return slots;
      if(cmd==='get_usage')return usage;
      if(cmd==='get_state')return {sessions,agg:'running',lang_resolved:'en'};
      if(cmd==='get_appearance')return {show_codex_extra:true,folds_for_fullscreen:true};
      if(cmd==='get_ui_flags')return {notch_visible:true,notch_on_hover:false};
      if(cmd==='get_notch_edge')return 'right';
      if(cmd==='get_move_handle')return false;
      if(cmd==='get_disabled_providers'||cmd==='get_activity'||cmd==='get_providers')return [];
      if(cmd==='get_codex'||cmd==='get_cursor'||cmd==='get_antigravity'||cmd==='get_glm'||cmd==='get_grok')return {...usage,windows:[{...usage.windows[0],id:cmd==='get_codex'?'primary':'session'}]};
      if(cmd==='get_glyphs')return {};
      return null;
    }},event:{listen:async(name,callback)=>{(listeners[name]??=[]).push(callback);return ()=>{};}}};
  });
}

test('六账户提交稳定的会话预算，屏幕 cap 控制可见行和隐藏行',async({page})=>{
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await notchBridge(page);await page.setViewportSize({width:360,height:800});await page.goto('/notch.html');
  await expect(page.locator('.cell')).toHaveCount(6);
  await expect.poll(()=>page.evaluate(()=>notchCalls.findLast(call=>call.cmd==='set_notch_content')?.args.content.budget_heights?.length)).toBe(13);
  const original=await page.evaluate(()=>notchCalls.findLast(call=>call.cmd==='set_notch_content').args.content);
  expect(original.count).toBe(6);
  expect(original.budget_heights[0]).toBeGreaterThan(0);
  expect(original.budget_heights[12]).toBeGreaterThan(original.budget_heights[4]);
  expect(original).toMatchObject({has_plan:false,has_token_usage:false,has_reset_credits:false});
  await page.locator('.cell[data-p="claude"]').hover();
  await page.evaluate(()=>emitNotch('notch_layout',{edge:'right',width:335,height:800,spacing:12,depth:69.9487,scale:1,session_cap:0}));
  await expect(page.locator('#card .s-row')).toHaveCount(0);
  await expect(page.locator('#card .s-more')).toContainText('10 more');
  await page.evaluate(()=>emitNotch('notch_layout',{edge:'right',width:335,height:800,spacing:12,depth:69.9487,scale:1,session_cap:8}));
  await expect(page.locator('#card .s-row')).toHaveCount(8);
  await expect(page.locator('#card .s-more')).toContainText('2 more');
  await page.evaluate(()=>emitNotch('activity',[]));
  await expect.poll(()=>page.evaluate(()=>notchCalls.filter(call=>call.cmd==='set_notch_content').length)).toBeGreaterThan(0);
  const latest=await page.evaluate(()=>notchCalls.findLast(call=>call.cmd==='set_notch_content').args.content);
  expect(latest).toEqual(original);
  expect(errors).toEqual([]);
});

test('四边卡片与刘海之间的空隙保持可命中，外侧透明区域可穿透',async({page})=>{
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await notchBridge(page);await page.goto('/notch.html');await expect(page.locator('.cell')).toHaveCount(6);
  for(const edge of ['right','left','top','bottom']){
    const vertical=edge==='right'||edge==='left',width=vertical?360:800,height=vertical?900:520;
    await page.setViewportSize({width,height});
    await page.evaluate(({edge,width,height})=>{
      emitNotch('notch_edge',edge);
      emitNotch('notch_layout',{edge,width,height,spacing:12,depth:verticalDepth(edge),scale:1,session_cap:2});
      function verticalDepth(value){return value==='right'||value==='left'?69.9487:97.0649;}
      showCard();reportHot();
    },{edge,width,height});
    await expect(page.locator('#card')).toHaveClass(/show/);
    const hit=await page.evaluate(()=>{
      const b=cardBridge(),x=(b.left+b.right)/2,y=(b.top+b.bottom)/2;
      return {width:b.right-b.left,height:b.bottom-b.top,inside:pointerInHot(x,y),outside:pointerInHot(2,2),hot:notchCalls.filter(call=>call.cmd==='set_hot').at(-1)?.args.rects};
    });
    expect(hit.width).toBeGreaterThan(0);expect(hit.height).toBeGreaterThan(0);
    expect(hit.inside).toBe(true);expect(hit.outside).toBe(false);
    expect(hit.hot).toHaveLength(5); // pill, tail, card, gap, settings orb
  }
  expect(errors).toEqual([]);
});
