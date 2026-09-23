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
      if(cmd==='get_deepseek_pricing_state'&&window.notchPricingFixture){
        const fixture=window.notchPricingFixture;fixture.reads++;
        return fixture.reads===1?{phase:'peak',next_phase:'offPeak',next_at:Date.now()+60000}:{phase:'offPeak',next_phase:'peak',next_at:Date.now()+3600000};
      }
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

test('刘海齿轮点击切换设置窗口，保留独立打开命令给菜单',async({page})=>{
  await notchBridge(page);await page.setViewportSize({width:360,height:1000});await page.goto('/notch.html');
  await expect(page.locator('.cell')).toHaveCount(6);
  await expect.poll(()=>page.evaluate(()=>!!orbAt&&document.getElementById('orb').classList.contains('placed'))).toBe(true);
  const hit=await page.evaluate(()=>{
    const {x,y}=orbAt,element=document.elementFromPoint(x,y);
    return {x,y,inside:near(orbAt,x,y),target:element?.closest('#orb')?.id||null};
  });
  expect(hit.inside).toBe(true);
  expect(hit.target).toBe('orb');
  await page.mouse.click(hit.x,hit.y);
  await expect.poll(()=>page.evaluate(()=>notchCalls.filter(call=>call.cmd==='toggle_settings').length)).toBe(1);
  expect(await page.evaluate(()=>notchCalls.filter(call=>call.cmd==='open_settings').length)).toBe(0);
});

test('本地运行时展开为每模型独立环和原版详情，隐藏模型不留聚合环',async({page})=>{
  await notchBridge(page);await page.setViewportSize({width:360,height:1050});await page.goto('/notch.html');
  const model={id:'qwen3:8b',name:'qwen3:8b',key:'qwen3:8b',size:8*1024**3,size_kind:'memory',gpu_size:4*1024**3,context:32768,quantization:'Q4',expires_at:null,brand:'qwen'};
  const performance={output_tokens:100,generation_seconds:2,measured_at:Date.now(),approximate:false,speed_text:'50 tok/s',headline_text:'50 tok/s',band:'veryFast'};
  await page.evaluate(({model,performance})=>emitNotch('providers',[
    {id:'ollama-local',name:'Ollama',enabled:true,snap:{status:'ok',windows:[],local_model:null}},
    {id:'ollama-local:model:qwen3:8b',name:'qwen3:8b',enabled:true,snap:{status:'ok',windows:[],local_model:model,source_provider_id:'ollama-local',shows_local_performance:true,local_context_fraction:.25,local_performance:performance}}
  ]),{model,performance});
  await expect(page.locator('.cell[data-p="ollama-local"]')).toHaveCount(0);
  await expect(page.locator('.cell[data-p="ollama-local:model:qwen3:8b"] .pct')).toHaveText('50 tok/s');
  await page.locator('.cell[data-p="ollama-local:model:qwen3:8b"]').hover();
  await expect(page.locator('#card')).toContainText('Qwen · Local');
  await expect(page.locator('#card')).toContainText('Last speed (derived)');
  await expect(page.locator('#card')).toContainText('VRAM');
  await expect(page.locator('#card')).toContainText('Context limit');
  await page.evaluate(({model,performance})=>emitNotch('providers',[
    {id:'ollama-local',name:'Ollama',enabled:true,snap:{status:'ok',windows:[]}},
    {id:'ollama-local:model:qwen3:8b',name:'qwen3:8b',enabled:false,snap:{status:'ok',windows:[],local_model:model,source_provider_id:'ollama-local',shows_local_performance:true,local_performance:performance}}
  ]),{model,performance});
  await expect(page.locator('.cell[data-p="ollama-local:model:qwen3:8b"]')).toHaveCount(0);
});

test('本地模型特殊字符 ID 不破坏 DOM，活动仅驱动自身圆环',async({page})=>{
  const errors=[];page.on('pageerror',error=>errors.push(error.message));
  await notchBridge(page);await page.goto('/notch.html');
  const ids=['ollama-local:model:quote"[a]','ollama-local:model:second'];
  await page.evaluate(ids=>{
    emitNotch('providers',[{id:'ollama-local',name:'Ollama',enabled:true,snap:{status:'ok',windows:[]}},
      ...ids.map(id=>({id,name:id.split(':').at(-1),enabled:true,snap:{status:'ok',windows:[],
        local_model:{id,name:id,key:id,size:1024,size_kind:'memory',gpu_size:null,context:null,quantization:null,expires_at:null},
        source_provider_id:'ollama-local'}}))]);
    emitNotch('activity',[{id:'only-first',provider:ids[0],state:'busy',name:'Thinking',detail:'Thinking',since:Date.now(),queued:0}]);
  },ids);
  await expect.poll(()=>page.evaluate(ids=>ids.map(id=>cellById(id)?.dataset.p||null),ids)).toEqual(ids);
  const arcs=await page.evaluate(ids=>ids.map(id=>cellById(id)?.querySelector('svg.activity')?.innerHTML.includes('arc-spin')),ids);
  expect(arcs).toEqual([true,false]);
  await page.evaluate(id=>{hoverId=id;showCard();},ids[0]);
  await expect(page.locator('#card')).toContainText('Thinking');
  expect(errors).toEqual([]);
});

test('非 Claude 活动仅在后端标记可聚焦时点击稳定会话 ID',async({page})=>{
  await notchBridge(page);await page.goto('/notch.html');
  const id='grok.run"[1]';
  await page.evaluate(id=>{
    emitNotch('activity',[{id,provider:'grok',state:'busy',name:'app',detail:'Grok',since:Date.now(),focusable:true}]);
    hoverId='grok';showCard();
  },id);
  await expect(page.locator('#card .s-row[data-session-id]')).toHaveCount(1);
  await page.locator('#card .s-row[data-session-id]').click();
  await expect.poll(()=>page.evaluate(()=>notchCalls.filter(call=>call.cmd==='focus_session').at(-1)?.args.id)).toBe(id);
  await page.evaluate(id=>{emitNotch('activity',[{id,provider:'grok',state:'busy',name:'app',detail:'Grok',since:Date.now(),focusable:false}]);renderCard();},id);
  await expect(page.locator('#card .s-row[data-session-id]')).toHaveCount(0);
  await page.evaluate(()=>{
    emitNotch('state',{sessions:[
      {id:'network',provider:'claude',state:'running',title:'Claude Desktop',prompt:'Working',started:Date.now(),focusable:false},
      {id:'terminal',provider:'claude',state:'running',title:'Terminal',prompt:'Working',started:Date.now(),focusable:true}
    ],agg:'running',lang_resolved:'en'});
    hoverId='claude';renderCard();
  });
  await expect(page.locator('#card .s-row')).toHaveCount(2);
  await expect(page.locator('#card .s-row[data-session-id]')).toHaveCount(1);
  await expect(page.locator('#card .s-row[data-session-id]')).toHaveAttribute('data-session-id','terminal');
});

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

test('固定 Swift 三服务示例的旧窗口 ID 与本地化仍可绘制',async({page})=>{
  await notchBridge(page);await page.goto('/notch.html');
  const result=await page.evaluate(()=>{
    const snap={headline:'claude.session',windows:[{id:'claude.session',label:'Current session',used:.73},{id:'claude.all',label:'All models',used:.07}]};
    setUiLanguage('zh');
    return {headline:headlineOf(snap,'claude')?.id,all:textCopy('All models'),daily:textCopy('Daily quota')};
  });
  expect(result).toEqual({headline:'claude.session',all:'全部模型',daily:'每日额度'});
});

test('Devin 余额卡片使用原版金额文本和独立分组，不显示原始美分',async({page})=>{
  await notchBridge(page);await page.goto('/notch.html');
  const html=await page.evaluate(()=>cardHtml({id:'devin',base:'devin',name:'Devin',snap:{status:'ok',fidelity:'official',windows:[
    {id:'daily',label:'Daily quota',used:.01,has_fraction:true,group:'Usage'},
    {id:'overage',label:'Extra usage balance',used:0,has_fraction:false,count:1428,used_text:'$14.28',group:'Extra usage'}
  ]}},0));
  expect(html).toContain('Extra usage balance');
  expect(html).toContain('$14.28');
  expect(html).not.toContain('1428');
});

test('原版示例的 ring 不显示 fidelity 近似符，OpenAI 复用原版 knot，关闭移动手柄仍保留设置弧',async({page})=>{
  await notchBridge(page);await page.goto('/notch.html');
  const result=await page.evaluate(()=>{
    glyphs.codex={kind:'svg',svg:'<svg data-test-openai-knot="true"></svg>',scale:.94};
    notchSlots=[{provider:'openai'}];
    extraProviders=[{id:'openai',name:'OpenAI',headline:'openai.session',enabled:true,
      snap:{status:'ok',fidelity:'manual',fetched_at:Date.now(),windows:[{id:'openai.session',label:'Current session',used:.21,derived:true}]}}];
    glyphEpoch++;showMove=false;renderRing();placeHandles();
    return {reading:pill.querySelector('.pct')?.textContent,
      knot:!!pill.querySelector('[data-test-openai-knot]'),
      move:moveHandle.classList.contains('placed'),orb:orb.classList.contains('placed')};
  });
  expect(result).toEqual({reading:'21%',knot:true,move:false,orb:true});
});

test('卡片使用真实元数据绘制金额、阻断、重置次数、Codex tokens 与 DeepSeek 明细',async({page})=>{
  const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await notchBridge(page);await page.goto('/notch.html');
  const result=await page.evaluate(()=>{
    deepSeekPricingState={phase:'peak',next_phase:'offPeak',next_at:Date.now()+3600000};
    appearance.deepseek_pricing_enabled=true;
    const now=Date.now();
    const detail={time_zone_seconds:28800,currency:'CNY',groups:[
      {api_key_id:'secret-key-join-id',days:[{date:now,cache_hit_tokens:100,cache_miss_tokens:200,output_tokens:300,requests:3,cost:1.25}]}
    ]};
    const snap={status:'ok',fetched_at:now,fidelity:'manual',windows:[
      {id:'spend',label:'Spend',used:.2,money:{currency:'CNY',spent:20,remaining:80}}
    ],block:{reason:'Rate limit reached',resets_at:now+3600000},
    reset_credits:{available_count:2,credits:[{id:'a',status:'available',expires_at:now+86400000}]},
    token_usage:{summary:{lifetime_tokens:1500000,peak_daily_tokens:12000,longest_running_turn_seconds:3600,current_streak_days:2,longest_streak_days:5},daily_usage_buckets:[{start_date:localDayKey(new Date()),tokens:1000}]},
    usage_detail:detail};
    return cardHtml({id:'deepseek',base:'deepseek',name:'DeepSeek',snap},0);
  });
  expect(result).toContain('~20% used');
  expect(result).toContain('¥100.00');
  expect(result).toContain('Rate limit reached');
  expect(result).toContain('2 unused resets');
  expect(result).toContain('1.5M');
  expect(result).toContain('UTC+8');
  expect(result).toContain('Peak pricing');
  expect(result).toContain('Daily cost');
  expect(result).not.toContain('secret-key-join-id');
  expect(errors).toEqual([]);
});

test('DeepSeek 卡片跨定价边界时重新读取原生 UTC 相位，隐藏后停止定时器',async({page})=>{
  await page.clock.install();await notchBridge(page);await page.goto('/notch.html');
  await page.evaluate(()=>{
    window.notchPricingFixture={reads:0};
    const now=Date.now();
    extraProviders=[{id:'deepseek',name:'DeepSeek',enabled:true,headline:'spend',snap:{status:'ok',fidelity:'official',windows:[{id:'spend',label:'Spend',used:.1}],usage_detail:{time_zone_seconds:28800,currency:'CNY',groups:[{api_key_id:'private',days:[{date:now,cache_hit_tokens:1,cache_miss_tokens:0,output_tokens:0,requests:1,cost:.1}]}]}}}];
    notchSlots=[{provider:'deepseek'}];renderRing();hoverId='deepseek';showCard();
  });
  await expect(page.locator('#card')).toContainText('Peak pricing');
  await page.clock.fastForward(60020);
  await expect.poll(()=>page.evaluate(()=>notchPricingFixture.reads)).toBe(2);
  await expect(page.locator('#card')).toContainText('Off-peak pricing');
  await page.evaluate(()=>hideCard());
  expect(await page.evaluate(()=>deepSeekPricingTimer)).toBe(0);
});

test('尺寸改变的原生 peek 只短暂展开，不生成通知卡且遵守 pinned 状态',async({page})=>{
  await page.clock.install();await notchBridge(page);await page.goto('/notch.html');
  await page.evaluate(()=>{onHover=true;pinned=false;pointerIn=false;setFolded(true);emitNotch('notch_peek',{seconds:1.2});});
  await expect(page.locator('body')).not.toHaveClass(/folded/);
  expect(await page.evaluate(()=>notchAlert)).toBeNull();
  await page.clock.fastForward(1201);
  await page.clock.fastForward(500);
  await expect(page.locator('body')).toHaveClass(/folded/);
  await page.evaluate(()=>{pinned=true;emitNotch('notch_peek',{seconds:1.2});});
  await page.clock.fastForward(1201);
  await page.clock.fastForward(500);
  await expect(page.locator('body')).not.toHaveClass(/folded/);
});

test('边框越界 2pt 仅移动 notch 内容，外侧设置弧保持原锚点',async({page})=>{
  await notchBridge(page);await page.setViewportSize({width:360,height:800});await page.goto('/notch.html');
  const result=await page.evaluate(()=>{
    notchEdge='left';document.body.dataset.edge='left';
    acceptNotchLayout({edge:'left',width:360,height:800,spacing:31.4017,depth:69.9487,scale:.8,session_cap:0});
    const p=pill.getBoundingClientRect(),o=orb.getBoundingClientRect();
    return {bleed:getComputedStyle(document.documentElement).getPropertyValue('--bezel-bleed').trim(),
      pillLeft:p.left,orbX:o.left+o.width/2,pillBottom:p.bottom};
  });
  expect(result.bleed).toBe('2.5px');
  expect(result.pillLeft).toBeCloseTo(-2.5,1);
  expect(result.orbX).toBeCloseTo(38.7,0);
});
