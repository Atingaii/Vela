import {test,expect} from '@playwright/test';
async function bridge(page,{deny=false,accounts=false}={}){
 await page.addInitScript(({deny,accounts})=>{
  let library={providers:[],mcp:[],skills:[]},enabled=[],prefs={attention:false,done:false};
  let slots=null,phoneEnabled=false,pairing=false,devices=[];
  let appearance={reset_time:'automatic',show_codex_extra:true,show_usage_pace:false,claude_daily_pace:false,folds_for_fullscreen:true,weekly_dashed:false,custom_scale:null,watch:.5,critical:.7};
  const listeners={};window.emitFixture=(name,payload)=>listeners[name]?.forEach(cb=>cb({payload}));
  window.calls=[];
  window.__TAURI__={core:{invoke:async(cmd,args)=>{
   window.calls.push({cmd,args});
   if(cmd==='get_appearance')return appearance;
   if(cmd==='set_appearance'){appearance=args.prefs;return appearance;}
   if(cmd==='get_library')return library;
   if(cmd==='get_notch_slots')return slots;
   if(cmd==='set_notch_slots'){slots=args.slots;return;}
   if(cmd==='get_tray_options'&&accounts)return [{id:'claude',label:'Claude',status:'ok'},{id:'codex',label:'Codex',status:'ok'}];
   if(cmd==='get_phone_link')return {enabled:phoneEnabled,port:8788,hosts:['192.168.1.2'],devices,link:args.pairing&&pairing?'codenotch://pair?v=3&h=192.168.1.2&p=8788&c=fixture':null,qr:args.pairing&&pairing?'<svg xmlns="http://www.w3.org/2000/svg"/>':null};
   if(cmd==='set_phone_link'){phoneEnabled=args.enabled;return;}
   if(cmd==='phone_pairing'){pairing=args.open;return;}
   if(cmd==='remove_phone'){devices=devices.filter(d=>d.deviceId!==args.deviceId);return;}

   if(cmd==='get_billing')return {currency:'CNY',cycle_day:15,subscription:30,rates:[]};
   if(cmd==='save_library'){library=args.library;return;}
   if(cmd==='list_edge_plugins')return {plugins:[],enabled};
   if(cmd==='set_edge_plugin'){enabled=args.on?[...enabled,args.id]:enabled.filter(x=>x!==args.id);return;}
   if(cmd==='edge_plugin_action')return args.id==='clipboard-preview'?{text:'<script>private clipboard</script>'}:[];
   if(cmd==='preview_sync')return {token:'reviewed',changes:[{path:'/fixture/.codex/config.toml',exists:true,summary:'切换已选择的供应商'}]};
   if(cmd==='apply_sync')return {files:1,backups:['/fixture/config.backup']};
   if(cmd==='get_notifications')return prefs;
   if(cmd==='set_notifications'){if(deny)throw new Error('系统拒绝通知权限');prefs=args.prefs;return prefs;}
   if(cmd==='get_lang'||cmd==='get_lang_resolved')return 'zh';
   if(cmd==='get_scale')return 1;
   if(cmd==='get_notch_edge')return 'right';
   if(cmd==='get_ui_flags')return {notch_visible:true,tray_visible:true,notch_on_hover:false};
   if(cmd==='get_system_look')return {mica:false,accent:[]};
   if(cmd==='get_update_state')return {configured:false,status:'idle'};
   if(cmd==='get_tray_options'||cmd==='get_notch_slots'||cmd==='get_monitors')return [];
   if(cmd==='get_autostart'||cmd==='get_hooks_installed')return false;
   if(cmd==='get_glyphs')return {};
   if(cmd==='read_ledger')return {rows:[{day:'2026-09-10',cli:'codex',model:'model-a',project:'<img src=x onerror=alert(1)>',input:100,output:25,cache_read:50,cache_write:0}],billing:{currency:'USD',cycle_day:1,subscription:20,rates:[]},cycle_start:'2026-09-01',cycle_end:'2026-10-01',known_cost:0,forecast:null,unknown_records:1,partial:false,files:1,skipped:0};
   return null;
  }},event:{listen:async(name,cb)=>{(listeners[name]??=[]).push(cb);return ()=>{};}},webview:{getCurrentWebview:()=>({onDragDropEvent:async()=>()=>{}})},window:{getCurrentWindow:()=>({close:async()=>{},startDragging:async()=>{}})}};
 },{deny,accounts});
}
test('迁移保留原版设置，通知拒绝后不假装保存',async({page})=>{
 await page.setViewportSize({width:860,height:600});const errors=[];page.on('pageerror',e=>errors.push(e.message));await bridge(page,{deny:true});await page.goto('/settings.html');
 await page.locator('#tab-appearance').click();await expect(page.locator('#seg-edge')).toBeVisible();await expect(page.locator('#seg-weekly')).toBeVisible();await expect(page.locator('#sw-move')).toBeVisible();await expect(page.locator('#lang')).toBeVisible();
 await page.locator('#tab-notifications').click();await page.locator('#notification-announce_session_end').click();await expect(page.locator('#notification-announce_session_end')).toHaveAttribute('aria-checked','true');await expect(page.getByText('系统拒绝通知权限')).toBeVisible();
 await page.locator('#tab-general').click();await expect(page.locator('#btn-workbench')).toBeHidden();expect(errors).toEqual([]);if(process.env.VELA_SCREENSHOTS)await page.screenshot({path:'/tmp/vela-settings.png'});
});
test('插件明确启用、手动读取且剪贴板内容作为文本显示',async({page})=>{
 await bridge(page);await page.goto('/workbench.html');await expect(page.locator('#clipboard-content')).toBeHidden();await page.locator('[data-plugin="clipboard-preview"]').click();await expect(page.locator('#clipboard-content')).toBeVisible();
 expect(await page.evaluate(()=>calls.filter(c=>c.cmd==='edge_plugin_action'&&c.args.action==='read').length)).toBe(0);
 await page.locator('#read-clipboard').click();await expect(page.locator('#clipboard')).toHaveText('<script>private clipboard</script>');await page.locator('#clear-clipboard').click();await expect(page.locator('#clipboard')).toBeEmpty();if(process.env.VELA_SCREENSHOTS)await page.screenshot({path:'/tmp/vela-workbench.png'});
});
test('供应商从保存到预览再应用，取消不会写 CLI',async({page})=>{
 await bridge(page);await page.goto('/workbench.html');await page.locator('#tab-providers').click();await page.locator('#provider-editor summary').click();
 for(const [id,v] of Object.entries({'provider-id':'demo','provider-name':'Demo','provider-url':'https://example.com/v1','provider-model':'model-a','provider-env':'DEMO_KEY'}))await page.locator('#'+id).fill(v);
 await page.locator('#provider-cli').selectOption('codex');await page.locator('#save-provider').click();await page.locator('[data-sync="provider"]').click();await expect(page.locator('#review')).toBeVisible();await page.locator('#cancel-review').click();expect(await page.evaluate(()=>calls.some(c=>c.cmd==='apply_sync'))).toBe(false);
 await page.locator('[data-sync="provider"]').click();await page.locator('#apply-review').click();await expect(page.locator('#status')).toContainText('已更新 1 个文件');
});
test('用量不自动扫描，未知费用无预测，多维汇总安全显示',async({page})=>{
 await bridge(page);await page.goto('/workbench.html');await page.locator('#tab-usage').click();expect(await page.evaluate(()=>calls.some(c=>c.cmd==='read_ledger'))).toBe(false);await expect(page.locator('#currency')).toHaveValue('CNY');await expect(page.locator('#cycle-day')).toHaveValue('15');await page.locator('#refresh-usage').click();await expect(page.locator('#forecast')).toHaveText('—');await expect(page.locator('#coverage')).toContainText('缺少单价');await page.locator('#dimension').selectOption('project');await expect(page.locator('#usage-rows')).toContainText('<img src=x onerror=alert(1)>');await expect(page.locator('#usage-rows img')).toHaveCount(0);
});
test('MCP 同步使用选中的平台，Skill 可保存正文',async({page})=>{
 await bridge(page);await page.goto('/workbench.html');await page.locator('#tab-shared').click();await page.locator('#mcp-editor summary').click();await page.locator('#mcp-id').fill('demo');await page.locator('#mcp-command').fill('node');await page.locator('#save-mcp').click();await page.locator('.target[value="gemini"]').uncheck();await page.locator('[data-sync="mcp"]').click();expect(await page.evaluate(()=>calls.find(c=>c.cmd==='preview_sync').args.request.targets)).toEqual(['claude','codex']);await page.locator('#cancel-review').click();await page.locator('#skill-editor summary').click();await page.locator('#skill-id').fill('review');await page.locator('#skill-description').fill('Review changes');await page.locator('#skill-instructions').fill('Read the diff.');await page.locator('#save-skill').click();await expect(page.locator('#skill-list')).toContainText('review');
});
test('无桌面桥接时明确报错，不显示伪造数据',async({page})=>{await page.goto('/workbench.html');await expect(page.locator('#status')).toContainText('需要在 Vela 桌面应用内打开');await page.locator('#tab-usage').click();await expect(page.locator('#cost')).toHaveText('—');});

test('账户排序被保留，关闭最后一个账户不会重新显示全部',async({page})=>{
 await bridge(page,{accounts:true});await page.goto('/settings.html');await page.locator('#tab-accounts').click();
 await expect(page.locator('#acc-on [data-account]')).toHaveCount(2);
 await page.locator('[data-reorder="codex"]').focus();await page.keyboard.press('ArrowUp');
 await expect(page.locator('#acc-on [data-account]').first()).toHaveAttribute('data-account','codex');
 expect(await page.evaluate(()=>calls.filter(c=>c.cmd==='set_notch_slots').at(-1).args.slots)).toEqual([{provider:'codex'},{provider:'claude'}]);
 await page.locator('[data-np="claude"]').click();await page.locator('[data-np="codex"]').click();await expect(page.locator('#acc-on [data-account]')).toHaveCount(0);
 expect(await page.evaluate(()=>calls.filter(c=>c.cmd==='set_notch_slots').at(-1).args.slots)).toEqual([]);
 await page.locator('[data-np="claude"]').click();await expect(page.locator('#acc-on [data-account]')).toHaveCount(1);
});
test('手机配对仅由明确操作开启，关闭窗口撤销配对码',async({page})=>{
 const errors=[];page.on('pageerror',e=>errors.push(e.message));await bridge(page);await page.goto('/settings.html');await page.locator('#tab-phone').click();
 await expect(page.locator('#phone-enabled')).toHaveAttribute('aria-checked','false');
 expect(await page.evaluate(()=>calls.some(c=>c.cmd==='phone_pairing'))).toBe(false);
 await page.locator('#phone-connect').click();await expect(page.locator('#phone-pairing')).toBeVisible();await expect(page.locator('#phone-qr img')).toHaveCount(1);
 expect(await page.evaluate(()=>calls.filter(c=>c.cmd==='phone_pairing').at(-1).args.open)).toBe(true);
 await page.locator('#phone-close').click();await expect(page.locator('#phone-pairing')).not.toBeVisible();await expect.poll(()=>page.evaluate(()=>calls.filter(c=>c.cmd==='phone_pairing').at(-1).args.open)).toBe(false);
 await expect(page.locator('#phone-qr img')).toHaveCount(0);expect(errors).toEqual([]);
});


test('刘海保持账户顺序、悬浮卡片与全关状态，图标刷新能替换现有标记',async({page})=>{
 const errors=[];page.on('pageerror',e=>errors.push(e.message));await bridge(page);
 await page.addInitScript(()=>{
  const invoke=window.__TAURI__.core.invoke;
  const snapshot={status:'ok',windows:[{id:'session',label:'Session',used:.72,resets_at:Date.now()+3600000},{id:'seven_day',label:'Weekly',used:.3,resets_at:Date.now()+86400000}],fetched_at:Date.now()};
  window.__TAURI__.core.invoke=async(cmd,args)=>{
   if(cmd==='get_notch_slots')return [{provider:'claude'},{provider:'codex'}];
   if(cmd==='get_usage')return snapshot;
   if(cmd==='get_codex')return {...snapshot,windows:snapshot.windows.map((w,i)=>({...w,id:i?'secondary':'primary'}))};
   if(['get_cursor','get_grok','get_antigravity','get_glm'].includes(cmd))return {status:'absent',windows:[]};
   if(cmd==='get_glyphs')return {claude:{kind:'svg',scale:.97,svg:'<svg viewBox="0 0 1 1" data-original="yes"><path d="M0 0 L1 1Z"/></svg>'}};
   if(cmd==='get_activity'||cmd==='get_providers')return [];
   if(cmd==='get_state')return {sessions:[],agg:'idle',lang_resolved:'en'};
   return invoke(cmd,args);
  };
 });
 await page.setViewportSize({width:350,height:650});await page.goto('/notch.html');
 await expect(page.locator('.cell')).toHaveCount(2);await expect(page.locator('.cell').first()).toHaveAttribute('data-p','claude');
 await expect(page.locator('[data-original]')).toHaveCount(1);
 await page.locator('.cell[data-p="claude"]').hover();await expect(page.locator('#card')).toHaveClass(/show/);
 await expect(page.locator('#card')).toContainText('Claude');
 const bounds=await page.locator('#card').boundingBox();expect(bounds.x).toBeGreaterThanOrEqual(0);expect(bounds.x+bounds.width).toBeLessThanOrEqual(350);
 if(process.env.VELA_SCREENSHOTS)await page.screenshot({path:'/tmp/vela-notch-migration.png'});
 await page.evaluate(()=>emitFixture('glyphs',{claude:{kind:'svg',svg:'<svg data-replaced="yes" viewBox="0 0 1 1"><path d="M0 0 L1 1Z"/></svg>'}}));
 await expect(page.locator('.cell [data-replaced]')).toHaveCount(1);
 await page.evaluate(()=>emitFixture('notch_slots',[]));await expect(page.locator('.cell')).toHaveCount(0);expect(errors).toEqual([]);
});

test('原版用量节奏和每日圆环开关默认关闭且独立保存',async({page})=>{
 const errors=[];page.on('pageerror',e=>errors.push(e.message));await bridge(page);await page.goto('/settings.html');await page.locator('#tab-appearance').click();
 for(const key of ['show_usage_pace','claude_daily_pace'])await expect(page.locator('#appearance-'+key)).toHaveAttribute('aria-checked','false');
 await page.locator('#appearance-show_usage_pace').click();await expect(page.locator('#appearance-show_usage_pace')).toHaveAttribute('aria-checked','true');
 await page.locator('#appearance-claude_daily_pace').click();await expect(page.locator('#appearance-claude_daily_pace')).toHaveAttribute('aria-checked','true');
 const saved=await page.evaluate(()=>calls.filter(c=>c.cmd==='set_appearance').at(-1).args.prefs);
 expect(saved).toMatchObject({show_usage_pace:true,claude_daily_pace:true,show_codex_extra:true,watch:.5,critical:.7});expect(errors).toEqual([]);
});
test('每日份额替代 Claude 主圆环，会话移到细环，关闭后恢复原始快照',async({page})=>{
 const errors=[];page.on('pageerror',e=>errors.push(e.message));await bridge(page);
 await page.addInitScript(()=>{
  const invoke=window.__TAURI__.core.invoke,now=Date.now(),day=86400000;
  window.__TAURI__.core.invoke=async(cmd,args)=>{
   if(cmd==='get_notch_slots')return [{provider:'claude'}];
   if(cmd==='get_usage')return {status:'ok',fetched_at:now,windows:[{id:'session',label:'Session',used:.8,resets_at:now+9000000,duration:18000},{id:'weekly_all',label:'Weekly',used:.1,resets_at:now+6.5*day,duration:604800}]};
   if(['get_codex','get_cursor','get_grok','get_antigravity','get_glm'].includes(cmd))return {status:'absent',windows:[]};
   if(cmd==='get_weekly_ring')return 'outside';
   if(cmd==='get_activity'||cmd==='get_providers')return [];
   if(cmd==='get_state')return {sessions:[],agg:'idle',lang_resolved:'en'};
   return invoke(cmd,args);
  };
 });
 await page.setViewportSize({width:350,height:650});await page.goto('/notch.html');await expect(page.locator('.cell .pct')).toHaveText('80%');
 await page.locator('.cell').hover();await expect(page.locator('.w-pace')).toHaveCount(0);
 await page.evaluate(()=>emitFixture('appearance',{show_usage_pace:true,claude_daily_pace:true}));
 await expect(page.locator('.cell .pct')).toHaveText('70%');await expect(page.locator('#card .w-label').first()).toHaveText('Daily pace');
 await expect(page.locator('.w-pace')).toHaveCount(2);await expect(page.locator('.w-pace').first()).toHaveText(' · 30% deficit');
 await expect(page.locator('.w-pace').first()).toHaveCSS('color','rgb(255, 149, 0)');await expect(page.locator('.w-used .w-pace')).toHaveCount(2);
 const arc=page.locator('svg.ring circle[opacity="0.85"]');const dash=await arc.getAttribute('stroke-dasharray');expect(Number(dash.split(' ')[0])/Number(dash.split(' ')[1])).toBeCloseTo(.8,2);
 await page.evaluate(()=>emitFixture('appearance',{show_usage_pace:false,claude_daily_pace:false}));await expect(page.locator('.cell .pct')).toHaveText('80%');await expect(page.locator('#card .w-label')).toHaveCount(2);await expect(page.locator('.w-pace')).toHaveCount(0);expect(errors).toEqual([]);
});


test('全屏自动收起仍可悬停唤醒，退出全屏或关闭选项后恢复',async({page})=>{
 await bridge(page);await page.goto('/notch.html');
 await expect.poll(()=>page.evaluate(()=>calls.some(c=>c.cmd==='get_ui_flags'))).toBe(true);
 await page.evaluate(()=>emitFixture('fullscreen',true));await expect(page.locator('body')).toHaveClass(/folded/);
 await page.evaluate(()=>emitFixture('notch_pointer',true));await expect(page.locator('body')).not.toHaveClass(/folded/);
 await page.evaluate(()=>emitFixture('notch_pointer',false));await expect(page.locator('body')).toHaveClass(/folded/);
 await page.evaluate(()=>emitFixture('notch_pinned',true));await expect(page.locator('body')).not.toHaveClass(/folded/);
 await page.evaluate(()=>emitFixture('notch_pinned',false));await expect(page.locator('body')).toHaveClass(/folded/);
 await page.evaluate(()=>emitFixture('fullscreen',false));await expect(page.locator('body')).not.toHaveClass(/folded/);
 await page.evaluate(()=>{emitFixture('fullscreen',true);emitFixture('appearance',{folds_for_fullscreen:false});});
 await expect(page.locator('body')).not.toHaveClass(/folded/);
});
test('跟随屏幕与固定屏幕可往返切换，全屏选项默认开启且保存',async({page})=>{
 await bridge(page);await page.addInitScript(()=>{
  const invoke=window.__TAURI__.core.invoke;let pinned=null;
  window.__TAURI__.core.invoke=async(cmd,args)=>{
   if(cmd==='get_monitors')return ['display1','display2'].map((id,i)=>({id,label:id,primary:i===0,current:id===(pinned||'display2'),pinned:id===pinned}));
   if(cmd==='set_notch_monitor'){pinned=args.id;window.calls.push({cmd,args});return;}
   return invoke(cmd,args);
  };
 });
 await page.goto('/settings.html');await page.locator('#tab-appearance').click();
 await expect(page.locator('#screen')).toHaveValue('');await page.locator('#screen').selectOption('display1');await expect(page.locator('#screen')).toHaveValue('display1');
 await page.locator('#screen').selectOption('');await expect(page.locator('#screen')).toHaveValue('');
 expect(await page.evaluate(()=>calls.filter(c=>c.cmd==='set_notch_monitor').at(-1).args.id)).toBe(null);
 await expect(page.locator('#appearance-folds_for_fullscreen')).toHaveAttribute('aria-checked','true');
 await page.locator('#appearance-folds_for_fullscreen').click();await expect(page.locator('#appearance-folds_for_fullscreen')).toHaveAttribute('aria-checked','false');
 expect(await page.evaluate(()=>calls.filter(c=>c.cmd==='set_appearance').at(-1).args.prefs.folds_for_fullscreen)).toBe(false);
});

test('额度提醒使用独立卡片，关闭后恢复用量，完成提醒只展开且点击回到会话',async({page})=>{
 await page.setViewportSize({width:360,height:650});await bridge(page);await page.addInitScript(()=>{
  const invoke=window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke=async(cmd,args)=>{
   if(cmd==='get_notch_slots')return [{provider:'claude'}];
   if(cmd==='get_usage')return {status:'ok',windows:[{id:'session',label:'Session',used:.25,resets_at:Date.now()+3600000}],fetched_at:Date.now()};
   if(cmd==='get_state')return {sessions:[],agg:'idle',lang_resolved:'en'};
   return invoke(cmd,args);
  };
 });
 await page.goto('/notch.html');await expect(page.locator('.cell')).toHaveCount(1);
 await page.evaluate(()=>emitFixture('notch_alert',{provider:'claude',provider_name:'Claude',kind:'sessionLimitReached',label:'5-hour',seconds:6,resets_at:Date.now()+3600000}));
 await expect(page.locator('#card')).toHaveClass(/usage-alert/);await expect(page.locator('.alert-status')).toHaveText('Session limit reached (100% used)');
 await expect(page.locator('.alert-reset')).toContainText('Resets at');await expect(page.locator('#card .win')).toHaveCount(0);
 expect(await page.locator('#card').evaluate(el=>Math.round(el.getBoundingClientRect().height))).toBe(79);
 if(process.env.VELA_SCREENSHOTS)await page.screenshot({path:'/tmp/vela-usage-alert.png'});
 await page.evaluate(()=>emitFixture('notch_alert',{provider:'claude',kind:'done',seconds:3,session_id:'older-session'}));
 await expect(page.locator('.alert-status')).toHaveText('Session limit reached (100% used)');
 await page.locator('.alert-dismiss').click();await expect(page.locator('#card')).not.toHaveClass(/show/);
 await page.evaluate(()=>{emitFixture('ui_flags',{notch_visible:true,notch_on_hover:true});emitFixture('notch_pointer',false);emitFixture('notch_alert',{provider:'claude',kind:'done',seconds:3,session_id:'session-42'});});
 await expect(page.locator('body')).not.toHaveClass(/folded/);await expect(page.locator('#card')).not.toHaveClass(/show/);
 await page.locator('.cell').click();await expect.poll(()=>page.evaluate(()=>calls.filter(c=>c.cmd==='focus_session').at(-1)?.args.id)).toBe('session-42');
 expect(await page.evaluate(()=>calls.some(c=>c.cmd==='refresh_usage'))).toBe(false);
});


test('账户套餐和剩余次数保留原始含义，无上限不画百分比条',async({page})=>{
 await page.setViewportSize({width:360,height:650});await bridge(page);await page.addInitScript(()=>{
  const invoke=window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke=async(cmd,args)=>{
   if(cmd==='get_notch_slots')return [{provider:'copilot'}];
   if(cmd==='get_providers')return [{id:'copilot',name:'GitHub Copilot',headline:'premium_interactions',enabled:true,snap:{status:'ok',plan:'<Pro & Team>',windows:[{id:'premium_interactions',label:'Premium requests',used:0,count:75,remaining:75}],fetched_at:Date.now()}}];
   if(cmd==='get_state')return {sessions:[],agg:'idle',lang_resolved:'en'};
   return invoke(cmd,args);
  };
 });
 await page.goto('/notch.html');await expect(page.locator('.cell')).toHaveCount(1);
 await page.locator('.cell').hover();await expect(page.locator('#card')).toHaveClass(/show/);
 await expect(page.locator('.c-plan')).toHaveText('<Pro & Team>');
 await expect(page.locator('.w-used')).toHaveText('75 left');
 await expect(page.locator('.w-track')).toHaveCount(0);
 await expect(page.locator('.cell .pct')).toHaveText('75');
});

test('独立账户仅显示属于自己的活动圆环与会话',async({page})=>{
 await page.setViewportSize({width:360,height:650});await bridge(page);await page.addInitScript(()=>{
  const invoke=window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke=async(cmd,args)=>{
   if(cmd==='get_notch_slots')return [{provider:'codex-work'},{provider:'codex-personal'}];
   if(cmd==='get_providers')return ['work','personal'].map(slug=>({id:'codex-'+slug,name:'Codex ('+slug+')',headline:'primary',enabled:true,snap:{status:'ok',windows:[{id:'primary',label:'5-hour',used:.1}],fetched_at:Date.now()}}));
   if(cmd==='get_activity')return [{id:'codex-work:thread',provider:'codex-work',state:'busy',name:'Work fixture',detail:'Working',since:Date.now()}];
   if(cmd==='get_state')return {sessions:[],agg:'idle',lang_resolved:'en'};
   return invoke(cmd,args);
  };
 });
 await page.goto('/notch.html');await expect(page.locator('.cell')).toHaveCount(2);
 await expect(page.locator('[data-p="codex-work"] .arc-spin')).toHaveCount(1);
 await expect(page.locator('[data-p="codex-personal"] .arc-spin')).toHaveCount(0);
 await page.locator('[data-p="codex-personal"]').hover();await expect(page.locator('#card')).not.toContainText('Work fixture');
 await page.locator('[data-p="codex-work"]').hover();await expect(page.locator('#card')).toContainText('Work fixture');
});

test('Antigravity 等待原因、完成脉冲和会话优先级保持原版语义',async({page})=>{
 await page.setViewportSize({width:360,height:650});await bridge(page);await page.addInitScript(()=>{
  const invoke=window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke=async(cmd,args)=>{
   if(cmd==='get_notch_slots')return [{provider:'gemini'}];
   if(cmd==='get_antigravity')return {status:'ok',windows:[{id:'model',label:'Model',used:.1}],fetched_at:Date.now()};
   if(cmd==='get_activity')return [{id:'antigravity-fixture',provider:'gemini',state:'waiting',name:'Antigravity',detail:'Permission',waiting_for:'Permission',since:Date.now()}];
   if(cmd==='get_state')return {sessions:[],agg:'idle',lang_resolved:'zh'};
   return invoke(cmd,args);
  };
 });
 await page.goto('/notch.html');await expect(page.locator('.cell')).toHaveCount(1);
 await expect(page.locator('.arc-pulse circle')).toHaveAttribute('stroke','#F2FF00');
 await page.locator('.cell').hover();await expect(page.locator('.c-sessions')).toContainText('权限');
 await page.evaluate(()=>emitFixture('activity',[{id:'antigravity-fixture',provider:'gemini',state:'success',name:'Antigravity',detail:'Complete',waiting_for:null,since:Date.now()}]));
 await expect(page.locator('.arc-pulse circle')).toHaveAttribute('stroke','#00FF88');
 await expect(page.locator('.c-sessions')).toContainText('已完成');
 await expect(page.locator('.s-dot')).toHaveCSS('background-color','rgb(0, 255, 136)');
 await page.evaluate(()=>emitFixture('activity',[
  {id:'done',provider:'gemini',state:'success',name:'Completed fixture',detail:'Complete',since:3000},
  {id:'busy',provider:'gemini',state:'busy',name:'Busy fixture',detail:'Working',since:2000},
  {id:'wait',provider:'gemini',state:'waiting',name:'Waiting fixture',detail:'Question',waiting_for:'Question',since:1000}
 ]));
 await expect(page.locator('.s-row').first()).toContainText('Waiting fixture');
 await expect(page.locator('.s-row').nth(1)).toContainText('Busy fixture');
 await expect(page.locator('.arc-pulse circle')).toHaveAttribute('stroke','#F2FF00');
 await page.evaluate(()=>emitFixture('activity',[]));await expect(page.locator('.arc-pulse')).toHaveCount(0);
});
