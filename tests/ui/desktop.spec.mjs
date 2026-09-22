import {test,expect} from '@playwright/test';
async function bridge(page,{deny=false,accounts=false}={}){
 await page.addInitScript(({deny,accounts})=>{
  let library={providers:[],mcp:[],skills:[]},enabled=[],prefs={attention:false,done:false};
  let slots=null,phoneEnabled=false,pairing=false,devices=[];
  const listeners={};window.emitFixture=(name,payload)=>listeners[name]?.forEach(cb=>cb({payload}));
  window.calls=[];
  window.__TAURI__={core:{invoke:async(cmd,args)=>{
   window.calls.push({cmd,args});
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
