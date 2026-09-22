import {test,expect} from '@playwright/test';
async function bridge(page,{deny=false}={}){
 await page.addInitScript(({deny})=>{
  let library={providers:[],mcp:[],skills:[]},enabled=[],prefs={attention:false,done:false};
  window.calls=[];
  window.__TAURI__={core:{invoke:async(cmd,args)=>{
   window.calls.push({cmd,args});
   if(cmd==='get_library')return library;
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
  }},event:{listen:async()=>()=>{}},webview:{getCurrentWebview:()=>({onDragDropEvent:async()=>()=>{}})},window:{getCurrentWindow:()=>({close:async()=>{},startDragging:async()=>{}})}};
 },{deny});
}
test('精简设置正常渲染，通知拒绝后不假装保存',async({page})=>{
 await page.setViewportSize({width:680,height:520});const errors=[];page.on('pageerror',e=>errors.push(e.message));await bridge(page,{deny:true});await page.goto('/settings.html');
 await page.locator('#tab-appearance').click();await expect(page.locator('#seg-edge')).toBeVisible();await expect(page.locator('#seg-weekly')).toHaveCount(0);await expect(page.locator('#sw-move')).toHaveCount(0);
 await page.locator('#tab-notifications').click();await page.locator('#sw-attention').click();await expect(page.locator('#sw-attention')).toHaveAttribute('aria-checked','false');await expect(page.getByText('系统拒绝通知权限')).toBeVisible();
 await page.locator('#tab-general').click();await expect(page.locator('#lang')).toBeVisible();await expect(page.locator('#btn-workbench')).toBeVisible();expect(errors).toEqual([]);if(process.env.VELA_SCREENSHOTS)await page.screenshot({path:'/tmp/vela-settings.png'});
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
