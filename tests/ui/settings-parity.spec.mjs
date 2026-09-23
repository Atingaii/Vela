import {test, expect} from '@playwright/test';

async function settingsBridge(page, connectedSlots = [], version = '1.16.0', initialSound = 'Glass') {
  await page.addInitScript(({initialSlots,version,initialSound}) => {
    const listeners = {};
    let appearance = {
      accent_color:'system', app_presence:'dock', reset_time:'automatic',
      show_codex_extra:true, show_usage_pace:false, claude_daily_pace:false,
      folds_for_fullscreen:true, weekly_dashed:false, custom_scale:null,
      watch:.5, critical:.7, deepseek_pricing_enabled:true,
      deepseek_pricing_schedule:{peak_weekdays:[2,3,4,5,6],windows:[{start_minute:60,end_minute:240},{start_minute:360,end_minute:600}]}
    };
    let notifications = {
      announce_session_end:true, peek_seconds:5, session_sound:true,
      finished_sound:initialSound, blocked_sound:'Funk', announce_session_limit:true,
      announce_weekly_limit:true, limit_sound:true, limit_sound_name:'Funk',
      announce_reset:true, reset_sound:true, reset_sound_name:'Glass', muted_providers:[]
    };
    let updates = {configured:true, automatic:true, available:null, checking:false, installing:false, message:null};
    let weekly = 'off';
    let customEndpoints = [];
    const customSecrets = {};
    let iconCounter = 0;
    let local = {ollama:'http://127.0.0.1:11434',lmstudio:'http://127.0.0.1:1234',disabled_models:[],ollama_metrics_enabled:false};
    let disabled = ['ollama-local'];
    let slots = initialSlots.map(provider => ({provider}));
    const webStates = Object.fromEntries(['deepseek','qianwenai','minimax'].map(id=>[id,{id,supported:true,signed_in:false,sign_in_open:false,reason:null}]));
    window.settingsFixture = {
      calls:[], failAppearance:false, holdAppearance:false, releaseAppearance:null,
      appearanceInFlight:0, maxAppearanceInFlight:0,
      failNotifications:false, failCustom:false, failLocal:false,
      customSecrets,customProbeResult:{health:'online',latency_ms:12,models:['local-a','local-b'],error:null},
      holdIcon:false,releaseIcon:null,holdCustomSecret:false,releaseCustomSecret:null,
      failWeb:false,showWebProviders:false,webStates,autostartProblem:null,failKeychain:false,
      providerPrefs:{minimax_china:false,gemini_token_budget:null},failProviderPrefs:false,lmTokenPresent:false,failLMToken:false,
      localActivity:{relay:{ready:true,status:'Listening',address:'http://127.0.0.1:11435',thinking_models:{},performances:{'llama3':{output_tokens:100,generation_seconds:2,measured_at:0,approximate:false}}},
        lmstudio:{status:'Reading server log',linked:true,history_loaded:false,today:{requests:0,input_tokens:0,output_tokens:0},model_count:0},checking:{'ollama-local':false,lmstudio:false}},
      refreshAccepted:true,monitors:[],
      trayOptions:null,providerRows:null,
      destinations:{},failAccountOpen:false,
      surfaceCap:{supported:false,glass_available:false,reduce_transparency:false,effective_surface_style:'solid'},
      localPresets:[{name:'Local vLLM (:8000)',url:'http://localhost:8000/v1',header:'Authorization',model:'',icon:'ollama',color:'#10B981'}],
      backgroundCustomProbe(id,patch){customEndpoints=customEndpoints.map(endpoint=>endpoint.id===id?{...endpoint,...patch}:endpoint);this.emit('providers',[]);},
      emit(name, payload) { for (const cb of listeners[name] || []) cb({payload}); },
      update(state) { updates = {...updates, ...state}; this.emit('update_state', updates); },
      setNotifications(patch) { notifications={...notifications,...patch}; this.emit('notifications',notifications); }
    };
    window.__TAURI__ = {
      core:{invoke:async (cmd, args) => {
        window.settingsFixture.calls.push({cmd, args});
        if (cmd === 'get_appearance') return {...appearance};
        if (cmd === 'set_appearance') {
          const fixture=window.settingsFixture;
          fixture.appearanceInFlight++;
          fixture.maxAppearanceInFlight=Math.max(fixture.maxAppearanceInFlight,fixture.appearanceInFlight);
          try {
            if(fixture.holdAppearance)await new Promise(resolve=>{fixture.releaseAppearance=resolve;});
            if (fixture.failAppearance) throw Error('fixture appearance save refused');
            appearance = {...args.prefs}; return {...appearance};
          } finally { fixture.appearanceInFlight--; }
        }
        if (cmd === 'get_notifications') return {...notifications};
        if (cmd === 'get_custom_endpoints') return customEndpoints.map(p => ({...p}));
        if (cmd === 'scan_local_engines') return window.settingsFixture.localPresets;
        if (cmd === 'test_custom_endpoint_draft') return {...window.settingsFixture.customProbeResult};
        if (cmd === 'get_custom_endpoint_key') return customSecrets[args.id]??null;
        if (cmd === 'save_custom_icon') {
          if(window.settingsFixture.holdIcon)await new Promise(resolve=>{window.settingsFixture.releaseIcon=resolve;});
          return args.id+'-'+(++iconCounter).toString(16).padStart(16,'0')+'.png';
        }
        if (cmd === 'get_custom_icon') return null;
        if (cmd === 'discard_custom_icon') return null;
        if (cmd === 'get_local_runtime_settings') return {...local};
        if (cmd === 'set_local_runtime_settings') {
          if (window.settingsFixture.failLocal) throw Error('fixture local settings save refused');
          local={...args.prefs}; return null;
        }
        if (cmd === 'get_local_models') return {};
        if (cmd === 'get_local_runtime_activity') return window.settingsFixture.localActivity;
        if (cmd === 'refresh_ring') return window.settingsFixture.refreshAccepted;
        if (cmd === 'get_providers') return window.settingsFixture.providerRows||[
          {id:'ollama-local',name:'Ollama',guidance:'',snap:{status:'absent',note:'Connecting to Ollama…'}},
          {id:'lmstudio',name:'LM Studio',guidance:'',snap:{status:'absent',note:'Connecting to LM Studio…'}}
        ];
        if (cmd === 'get_account_destination') return window.settingsFixture.destinations[args.id]||null;
        if (cmd === 'open_account_destination') {
          if(window.settingsFixture.failAccountOpen)throw Error('fixture account destination refused');
          return window.settingsFixture.destinations[args.id]||null;
        }
        if (cmd === 'get_web_session_state') return {...webStates[args.id]};
        if (cmd === 'get_provider_settings') return {...window.settingsFixture.providerPrefs};
        if (cmd === 'set_provider_settings') {
          if(window.settingsFixture.failProviderPrefs)throw Error('fixture provider settings refused');
          window.settingsFixture.providerPrefs={minimax_china:args.minimaxChina,gemini_token_budget:args.geminiTokenBudget};return null;
        }
        if (cmd === 'allow_claude_keychain_access') {if(window.settingsFixture.failKeychain)throw Error('fixture keychain request refused');return null;}
        if (cmd === 'open_web_session') {
          if(window.settingsFixture.failWeb)throw Error('fixture login refused');
          webStates[args.id]={...webStates[args.id],sign_in_open:true};
          return {...webStates[args.id]};
        }
        if (cmd === 'get_tray_options'&&window.settingsFixture.trayOptions)return window.settingsFixture.trayOptions;
        if (cmd === 'get_tray_options'&&window.settingsFixture.showWebProviders)
          return ['deepseek','qianwenai','minimax'].map(id=>({id,label:{deepseek:'DeepSeek',qianwenai:'QianwenAI',minimax:'MiniMax'}[id],status:'needsAuth'}));
        if (cmd === 'set_provider_enabled') {
          if (window.settingsFixture.failLocal) throw Error('fixture monitor save refused');
          disabled=disabled.filter(id=>id!==args.id);if(!args.value)disabled.push(args.id);
          slots=slots.filter(slot=>slot.provider!==args.id);if(args.value)slots.push({provider:args.id});
          if(window.settingsFixture.providerRows){
            window.settingsFixture.providerRows=window.settingsFixture.providerRows.map(row=>row.id===args.id?{...row,enabled:args.value}:row);
            window.settingsFixture.emit('providers',window.settingsFixture.providerRows);
          }
          return null;
        }
        if (cmd === 'get_disabled_providers') return [...disabled];
        if (cmd === 'save_custom_endpoint') {
          if (window.settingsFixture.failCustom) throw Error('fixture endpoint save refused');
          const index=customEndpoints.findIndex(p => p.id===args.endpoint.id);
          if (index<0) customEndpoints.push({...args.endpoint}); else customEndpoints[index]={...args.endpoint};
          return null;
        }
        if (cmd === 'delete_custom_endpoint') {customEndpoints=customEndpoints.filter(p=>p.id!==args.id);return null;}
        if (cmd === 'probe_custom_endpoint') return customEndpoints.find(p=>p.id===args.id);
        if (cmd === 'get_lmstudio_token_state') return {present:window.settingsFixture.lmTokenPresent};
        if (cmd === 'save_provider_secret') {
          if(args.id.startsWith('endpoint-')){
            if(window.settingsFixture.holdCustomSecret)await new Promise(resolve=>{window.settingsFixture.releaseCustomSecret=resolve;});
            if(args.secret)customSecrets[args.id.slice('endpoint-'.length)]=args.secret;
            else delete customSecrets[args.id.slice('endpoint-'.length)];
          }
          if(args.id==='lmstudio-api-token'){if(window.settingsFixture.failLMToken)throw Error('fixture token vault refused');window.settingsFixture.lmTokenPresent=!!args.secret;}
          return null;
        }
        if (cmd === 'set_notifications') {
          if (window.settingsFixture.failNotifications) throw Error('fixture notification save refused');
          notifications = {...args.prefs}; return {...notifications};
        }
        if (cmd === 'get_system_look') return {mica:false, accent:[], symbols:{}};
        if (cmd === 'get_menu_bar_choices') return [{id:'claude',name:'Claude'},{id:'codex',name:'Codex'},{id:'deepseek',name:'DeepSeek'}];
        if (cmd === 'get_surface_capability') return {...window.settingsFixture.surfaceCap};
        if (cmd === 'get_autostart_problem') return window.settingsFixture.autostartProblem;
        if (cmd === 'get_update_state') return {...updates};
        if (cmd === 'set_automatic_updates') { updates.automatic = args.on; return {...updates}; }
        if (cmd === 'get_weekly_ring') return weekly;
        if (cmd === 'set_weekly_ring') { weekly = args.placement; return weekly; }
        if (cmd === 'get_move_handle') return true;
        if (cmd === 'get_scale') return 1;
        if (cmd === 'set_scale') return args.scale;
        if (cmd === 'get_notch_edge') return 'right';
        if (cmd === 'get_ui_flags') return {notch_visible:true, notch_on_hover:false, tray_visible:true};
        if (cmd === 'get_lang') return 'en';
        if (cmd === 'get_lang_resolved') return 'en';
        if (cmd === 'get_monitors') return window.settingsFixture.monitors.map(m=>({...m}));
        if (cmd === 'get_notch_slots') return slots.map(slot=>({...slot}));
        if (cmd === 'get_tray_options') return [];
        if (cmd === 'get_alert_sounds') return ['Glass','Funk'];
        if (cmd === 'get_autostart' || cmd === 'get_hooks_installed') return false;
        return null;
      }},
      event:{listen:async (name, cb) => { (listeners[name] ||= []).push(cb); return () => {}; }},
      app:{getVersion:async () => version},
      window:{getCurrentWindow:() => ({close:async () => {}, startDragging:async () => {}})}
    };
  }, {initialSlots:connectedSlots,version,initialSound});
}

test('外观版式遵循原版分组、顺序与控件类型', async ({page}) => {
  await settingsBridge(page);
  await page.setViewportSize({width:860, height:600});
  await page.goto('/settings.html');
  await expect(page.locator('#tab-phone')).toBeHidden(); // pinned Swift PhoneLink.isAvailable=false
  await page.locator('#tab-appearance').click();
  await expect(page.locator('#pane-appearance > .sec')).toHaveText(['Notch','Usage Limits','App']);
  await expect(page.locator('#seg-reset_time button')).toHaveCount(2);
  await expect(page.locator('#seg-reset_time [aria-pressed="true"]')).toHaveAttribute('data-v','automatic');
  await expect(page.locator('#row-weekly_dashed')).toBeHidden();
  await expect(page.locator('#preset-size-controls')).toBeVisible();
  await expect(page.locator('#custom-size-controls')).toBeHidden();
  const groups = await page.locator('#pane-appearance > .group').count();
  expect(groups).toBe(3);
  const ordered = await page.locator('#pane-appearance > .group').first().locator('.item:not(.cap)').evaluateAll(items => items.map(item => item.textContent.trim().split(/\s{2,}/)[0]));
  expect(ordered.join('|')).toMatch(/Reset time.*Show usage pace.*Show Spark and code review.*Weekly ring.*Claude daily pace ring.*Show.*Fold for full-screen apps.*Edge.*Size/);
  const size = await page.locator('#side').evaluate(el => el.getBoundingClientRect().width);
  const head = await page.locator('#head').evaluate(el => el.getBoundingClientRect().height);
  expect(size).toBe(220);
  expect(head).toBeGreaterThanOrEqual(80);
  expect(head).toBeLessThanOrEqual(82);
  await expect(page.locator('#tab-appearance .badge svg')).toHaveCount(1); // no native symbol payload
  await expect(page.locator('#tab-appearance .system-symbol')).toHaveCount(0);
});

test('DeepSeek UTC 定价规则按 Swift 分组读写，保存失败回滚',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-deepseek').click();
  await expect(page.locator('#pane-deepseek > .sec')).toHaveText(['Peak/off-peak pricing','Peak rule']);
  await expect(page.locator('#deepseek-pricing-enabled')).toHaveAttribute('aria-checked','true');
  await expect(page.locator('[data-pricing-day]')).toHaveCount(7);
  await expect(page.locator('[data-pricing-window]')).toHaveCount(2);
  await page.evaluate(()=>{settingsFixture.failAppearance=true;});
  await page.locator('[data-pricing-day="7"]').click();
  await expect(page.locator('#strip')).toContainText('fixture appearance save refused');
  await expect(page.locator('[data-pricing-day="7"]')).not.toBeChecked();
  await page.evaluate(()=>{settingsFixture.failAppearance=false;});
  await page.locator('[data-pricing-day="7"]').check();
  await expect(page.locator('[data-pricing-day="7"]')).toBeChecked();
  await page.locator('#deepseek-add-window').click();
  await expect(page.locator('[data-pricing-window]')).toHaveCount(3);
  const saved=await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1).args.prefs.deepseek_pricing_schedule);
  expect(saved.peak_weekdays).toEqual([2,3,4,5,6,7]);
  expect(saved.windows.at(-1)).toEqual({start_minute:0,end_minute:60});
  await page.locator('#deepseek-pricing-enabled').click();
  await expect(page.locator('#deepseek-peak-rule [data-pricing-day="2"]')).toBeDisabled();
  await page.locator('#deepseek-restore').click();
  await expect(page.locator('[data-pricing-window]')).toHaveCount(2);
});

test('菜单栏限额仅在菜单栏模式出现，账户选择保存但不改变采集开关',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-appearance').click();
  await page.evaluate(()=>{document.documentElement.dataset.platform='macos';renderAppearance();});
  await expect(page.locator('#menu-bar-controls')).toBeHidden();
  await page.locator('#seg-presence [data-v="menuBar"]').click();
  await expect(page.locator('#menu-bar-controls')).toBeVisible();
  await page.locator('#appearance-shows_limits_in_menu_bar').click();
  await expect(page.locator('#menu-bar-choices [data-menu-bar-id]')).toHaveCount(3);
  await expect(page.locator('[data-menu-bar-id="claude"]')).toHaveAttribute('aria-checked','true');
  await expect(page.locator('[data-menu-bar-id="codex"]')).toHaveAttribute('aria-checked','true');
  await page.locator('[data-menu-bar-id="deepseek"]').click();
  const saved=await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1).args.prefs.menu_bar_providers);
  expect(saved).toEqual(['claude','codex','deepseek']);
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_provider_enabled'))).toHaveLength(0);
  await expect(page.locator('#menu-bar-overflow')).toBeVisible();
});

test('系统强调色变化事件即时更新系统色选项，非法颜色忽略',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-appearance').click();
  await page.evaluate(()=>settingsFixture.emit('system_accent_changed','#123abc'));
  await expect.poll(()=>page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--accent').trim())).toBe('#123abc');
  await page.evaluate(()=>settingsFixture.emit('system_accent_changed','javascript:bad'));
  expect(await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--accent').trim())).toBe('#123abc');
});

test('多屏范围写入持久偏好，Surface 只在 macOS 26 支持时出现并反映降低透明度',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-appearance').click();
  await expect(page.locator('#surface-controls')).toBeHidden();
  await page.locator('#seg-scope [data-v="allDisplays"]').click();
  await expect(page.locator('#seg-scope [aria-pressed="true"]')).toHaveAttribute('data-v','allDisplays');
  await expect(page.locator('#row-screen')).toBeHidden();
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1).args.prefs.notch_scope)).toBe('allDisplays');
  await page.evaluate(()=>{settingsFixture.surfaceCap={supported:true,glass_available:false,reduce_transparency:true,effective_surface_style:'solid'};refreshSurfaceCapability();});
  await expect(page.locator('#surface-controls')).toBeVisible();
  await expect(page.locator('#cap-surface')).toContainText('Reduce Transparency is on');
  await page.locator('#seg-surface [data-v="darkGlass"]').click();
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1).args.prefs.surface_style)).toBe('darkGlass');
  await page.evaluate(()=>{settingsFixture.failAppearance=true;});
  await page.locator('#seg-scope [data-v="mainDisplay"]').click();
  await expect(page.locator('#strip')).toContainText('fixture appearance save refused');
  await expect(page.locator('#seg-scope [aria-pressed="true"]')).toHaveAttribute('data-v','allDisplays');
});

test('Claude Keychain 被拒后仅该账户显示 Allow access，调用定向授权并保留失败态',async({page})=>{
  await settingsBridge(page,['claude','codex']);await page.goto('/settings.html');
  await page.waitForFunction(()=>providerMetadata.length===2);
  await page.evaluate(()=>settingsFixture.emit('providers',[{id:'claude',was_refused_access:true},{id:'codex',was_refused_access:false}]));
  await expect(page.locator('[data-account="claude"] [data-allow-keychain]')).toBeVisible();
  await expect(page.locator('[data-account="codex"] [data-allow-keychain]')).toHaveCount(0);
  await page.locator('[data-account="claude"] [data-np="claude"]').click();
  await expect(page.locator('[data-account="claude"] [data-allow-keychain]')).toHaveCount(0);
  await page.locator('[data-account="claude"] [data-np="claude"]').click();
  await expect(page.locator('[data-account="claude"] [data-allow-keychain]')).toBeVisible();
  await page.evaluate(()=>{settingsFixture.failKeychain=true;});
  await page.locator('[data-account="claude"] [data-allow-keychain]').click();
  await expect(page.locator('#strip')).toContainText('fixture keychain request refused');
  await expect(page.locator('[data-account="claude"] [data-allow-keychain]')).toBeVisible();
  await page.evaluate(()=>{settingsFixture.failKeychain=false;});
  await page.locator('[data-account="claude"] [data-allow-keychain]').click();
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='allow_claude_keychain_access').at(-1).args)).toEqual({id:'claude'});
});

test('账户摘要优先于状态，拒绝访问与续签独立显示，关闭后只显示退出说明',async({page})=>{
  await settingsBridge(page,['claude','codex']);await page.goto('/settings.html');
  await page.evaluate(()=>settingsFixture.emit('providers',[
    {id:'claude',was_refused_access:true,needs_sign_in_renewal:true,account:{label:'user@example.com',plan:'pro',source:'Claude Code',manage_url:'https://claude.ai/settings/usage'}},
    {id:'codex',was_refused_access:false,needs_sign_in_renewal:false,account:{label:'second@example.com',plan:'plus',source:'Codex',manage_url:'https://chatgpt.com/#settings/Account'}}
  ]));
  await expect(page.locator('[data-account="claude"] .account-summary')).toContainText('user@example.com · Pro · via Claude Code');
  await expect(page.locator('[data-account="claude"] [data-allow-keychain]')).toBeVisible();
  await expect(page.locator('[data-account="claude"] .renewal')).toContainText('sign-in renewed');
  await expect(page.locator('[data-account="codex"] .renewal')).toHaveCount(0);
  await page.locator('[data-account="claude"] [data-np]').click();
  await expect(page.locator('[data-account="claude"] .acct-detail')).toContainText('Signed out — nothing is read');
  await expect(page.locator('[data-account="claude"] [data-allow-keychain]')).toHaveCount(0);
  await expect(page.locator('[data-account="claude"] .renewal')).toHaveCount(0);
});

test('账户 Open 和 Switch 只传 ID，由原生端选择所属 App 或网站并显示失败',async({page})=>{
  await settingsBridge(page,['claude','codex']);await page.goto('/settings.html');
  await page.waitForFunction(()=>providerMetadata.length===2);
  await page.evaluate(()=>{
    settingsFixture.destinations={
      claude:{kind:'website',label:'claude.ai',help:'source website'},
      codex:{kind:'app',label:'Codex',help:'owner app'}
    };
    settingsFixture.emit('providers',[
      {id:'claude',enabled:true,account:{label:'first@example.com',plan:'pro',source:'Claude Code',manage_url:'https://claude.ai/settings/usage'}},
      {id:'codex',enabled:true,account:{label:'second@example.com',plan:'plus',source:'Codex',manage_url:'https://chatgpt.com/#settings/Account'}}
    ]);
  });
  await page.locator('#tab-accounts').click();
  await expect(page.locator('[data-account="claude"] [data-account-open]')).toHaveText('Open claude.ai');
  await expect(page.locator('[data-account="claude"] [data-account-switch]')).toHaveCount(0);
  await expect(page.locator('[data-account="codex"] [data-account-open]')).toHaveText('Open Codex');
  await expect(page.locator('[data-account="codex"] [data-account-switch]')).toHaveText('Switch…');
  await page.locator('[data-account="codex"] [data-account-switch]').click();
  await page.locator('[data-account="claude"] [data-account-open]').click();
  const opens=await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='open_account_destination').map(c=>c.args));
  expect(opens).toEqual([{id:'codex'},{id:'claude'}]);
  await page.evaluate(()=>{settingsFixture.failAccountOpen=true;});
  await page.locator('[data-account="codex"] [data-account-open]').click();
  await expect(page.locator('#strip')).toContainText('fixture account destination refused');
});

test('已连接账户的原生目的地随账号元数据出现和撤销即时更新',async({page})=>{
  await settingsBridge(page,['claude']);await page.goto('/settings.html');
  await page.waitForFunction(()=>providerMetadata.length===2);
  await page.locator('#tab-accounts').click();
  await page.evaluate(()=>settingsFixture.emit('providers',[{id:'claude',enabled:true,account:{label:'first@example.com',plan:'pro',source:'Claude Code',manage_url:null}}]));
  await expect(page.locator('[data-account="claude"] [data-account-open]')).toHaveCount(0);
  await page.evaluate(()=>{
    settingsFixture.destinations.claude={kind:'website',label:'claude.ai',help:'source website'};
    settingsFixture.emit('providers',[{id:'claude',enabled:true,account:{label:'first@example.com',plan:'pro',source:'Claude Code',manage_url:'https://claude.ai/settings/usage'}}]);
  });
  await expect(page.locator('[data-account="claude"] [data-account-open]')).toHaveText('Open claude.ai');
  await page.evaluate(()=>{
    delete settingsFixture.destinations.claude;
    settingsFixture.emit('providers',[{id:'claude',enabled:true,account:{label:'first@example.com',plan:'pro',source:'Claude Code',manage_url:null}}]);
  });
  await expect(page.locator('[data-account="claude"] [data-account-open]')).toHaveCount(0);
});

test('设置首次打开不编辑字段，点击焦点环保留编辑，空白与重开只结束编辑不丢草稿',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');
  await page.locator('#tab-lmstudio').click();
  expect(await page.evaluate(()=>document.activeElement?.matches('input,textarea'))).toBeFalsy();
  const token=page.locator('#lmstudio-token');
  await token.fill('draft-token');
  await expect(token).toBeFocused();
  const box=await token.boundingBox();
  await page.mouse.click(box.x-2,box.y+box.height/2);
  await expect(token).toBeFocused();
  await page.locator('#pane-lmstudio > .sec').click();
  await expect(token).not.toBeFocused();
  await expect(token).toHaveValue('draft-token');
  await token.focus();
  await page.evaluate(()=>settingsFixture.emit('settings_opened',null));
  await expect(token).not.toBeFocused();
  await expect(token).toHaveValue('draft-token');
});

test('MiniMax 区域与 Gemini API 月预算属于各自账户行，失败按原值回滚',async({page})=>{
  await settingsBridge(page,['minimax','gemini-api']);await page.goto('/settings.html');
  await page.evaluate(()=>{options=[{id:'minimax',label:'MiniMax',status:'ok'},{id:'gemini-api',label:'Gemini API',status:'ok'}];renderAccounts();});
  await expect(page.locator('#provider-config')).toHaveCount(0);
  await expect(page.locator('[data-account="minimax"] [data-minimax-region]')).toBeVisible();
  await expect(page.locator('[data-account="gemini-api"] [data-gemini-budget]')).toBeVisible();
  await page.evaluate(()=>{settingsFixture.failProviderPrefs=true;});
  await page.locator('[data-account="minimax"] [data-minimax-region]').selectOption('china');
  await expect(page.locator('#strip')).toContainText('fixture provider settings refused');
  await expect(page.locator('[data-account="minimax"] [data-minimax-region]')).toHaveValue('global');
  await page.evaluate(()=>{settingsFixture.failProviderPrefs=false;});
  await page.locator('[data-account="gemini-api"] [data-gemini-budget]').fill('120000');
  await page.locator('[data-account="gemini-api"] [data-gemini-budget]').press('Tab');
  await expect.poll(()=>page.evaluate(()=>settingsFixture.providerPrefs.gemini_token_budget)).toBe(120000);
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_provider_settings').at(-1).args)).toEqual({minimaxChina:false,geminiTokenBudget:120000});
});

test('应用内网页登录只在可隔离平台展示，真实调用登录并保留失败状态',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');
  await page.evaluate(()=>{settingsFixture.showWebProviders=true;notchSlots=null;refreshOptions();});
  await expect(page.locator('[data-account="deepseek"] [data-web-sign-in]')).toBeVisible();
  await page.locator('[data-account="deepseek"] [data-web-sign-in]').click();
  await expect.poll(()=>page.evaluate(()=>settingsFixture.calls.findLast(call=>call.cmd==='open_web_session')?.args))
    .toEqual({id:'deepseek',switching:false,minimaxChina:false});
  await page.evaluate(()=>{settingsFixture.webStates.deepseek={...settingsFixture.webStates.deepseek,signed_in:true,sign_in_open:false};settingsFixture.emit('web_session_state',settingsFixture.webStates.deepseek);});
  await expect(page.locator('[data-account="deepseek"] [data-switch="true"]')).toBeVisible();
  await page.evaluate(()=>{settingsFixture.webStates.qianwenai={...settingsFixture.webStates.qianwenai,supported:false,reason:'Private profile unavailable'};settingsFixture.emit('web_session_state',settingsFixture.webStates.qianwenai);});
  await expect(page.locator('[data-account="qianwenai"] [data-web-sign-in]')).toHaveCount(0);
  await expect(page.locator('[data-account="qianwenai"]')).toContainText('Private profile unavailable');
  await page.evaluate(()=>{settingsFixture.failWeb=true;});
  await page.locator('[data-account="minimax"] [data-web-sign-in]').click();
  await expect(page.locator('#strip')).toContainText('fixture login refused');
  expect(await page.evaluate(()=>settingsFixture.webStates.minimax.signed_in)).toBe(false);
});

test('自定义端点预设只填表，完整字段写入且启停失败回滚', async ({page}) => {
  await settingsBridge(page);
  await page.goto('/settings.html');
  await page.locator('#tab-custom').click();
  await expect(page.locator('#custom-list')).toContainText('No custom endpoints yet');
  await page.locator('#custom-templates-toggle').click();
  await expect(page.locator('#custom-templates [data-custom-template]')).toHaveCount(8);
  await page.locator('#custom-templates [data-custom-template="0"]').click();
  await expect(page.locator('#custom-name')).toHaveValue('OpenRouter');
  await expect(page.locator('#custom-url')).toHaveValue('https://openrouter.ai/api/v1');
  expect(await page.evaluate(() => settingsFixture.calls.filter(c => c.cmd==='save_custom_endpoint'))).toHaveLength(0);
  await page.locator('#seg-custom-unit [data-v="tokens"]').click();
  await expect(page.locator('#custom-budget-label')).toContainText('M tokens');
  await page.locator('#custom-budget').fill('10');
  await page.locator('#custom-used').fill('2.5');
  await page.locator('#custom-currency').check();
  await page.locator('#custom-remaining').check();
  await page.locator('[data-custom-icon="claude"]').click();
  await page.locator('[data-custom-color="#10B981"]').click();
  await page.locator('#custom-form [type="submit"]').click();
  await expect(page.locator('#custom-editor-wrap')).toBeHidden();
  const saved = await page.evaluate(() => settingsFixture.calls.find(c => c.cmd==='save_custom_endpoint').args.endpoint);
  expect(saved).toMatchObject({name:'OpenRouter',url:'https://openrouter.ai/api/v1',model:'openai/gpt-4o',unit:'tokens',budget:10,used:2.5,icon:'claude',color:'#10b981',display_remaining:true,show_currency:true,enabled:true});
  await expect(page.locator('#custom-list')).toContainText('OpenRouter');
  await page.evaluate(() => {settingsFixture.failCustom=true;});
  await page.locator('[data-custom-toggle]').click();
  await expect(page.locator('#strip')).toContainText('fixture endpoint save refused');
  await expect(page.locator('[data-custom-toggle]')).toHaveAttribute('aria-checked','true');
  await page.evaluate(() => {settingsFixture.failCustom=false;});
  await page.locator('[data-custom-toggle]').click();
  await expect(page.locator('[data-custom-toggle]')).toHaveAttribute('aria-checked','false');
});

test('自定义端点本地扫描、草稿探测、双预算、重置与自有图片经过真实交互保存',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-custom').click();
  await page.locator('#custom-scan').click();
  await expect(page.locator('#custom-discovered [data-discovered]')).toHaveCount(1);
  expect(await page.evaluate(()=>settingsFixture.calls.some(call=>call.cmd==='scan_local_engines'))).toBe(true);
  await page.locator('#custom-discovered [data-discovered]').click();
  await expect(page.locator('#custom-url')).toHaveValue('http://localhost:8000/v1');
  await page.locator('#custom-draft-probe').click();
  await expect(page.locator('#custom-draft-result')).toContainText('online (12 ms)');
  await expect(page.locator('#custom-model')).toHaveJSProperty('tagName','SELECT');
  await expect(page.locator('#custom-model')).toHaveValue('local-a');
  await page.locator('#custom-budget').fill('20');await page.locator('#custom-used').fill('4.25');
  await page.locator('#seg-custom-unit [data-v="tokens"]').click();
  await page.locator('#custom-budget').fill('10');await page.locator('#custom-used').fill('2.5');
  await page.locator('#seg-custom-unit [data-v="currency"]').click();
  await expect(page.locator('#custom-budget')).toHaveValue('20');await expect(page.locator('#custom-used')).toHaveValue('4.25');
  await page.locator('#custom-reset-used').click();await expect(page.locator('#custom-used')).toHaveValue('0');
  await page.locator('#seg-custom-unit [data-v="tokens"]').click();await expect(page.locator('#custom-used')).toHaveValue('2.5');
  const base64=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=2;canvas.height=2;canvas.getContext('2d').fillRect(0,0,2,2);return canvas.toDataURL('image/png').split(',')[1];});
  await page.locator('#custom-image-file').setInputFiles({name:'icon.png',mimeType:'image/png',buffer:Buffer.from(base64,'base64')});
  await expect(page.locator('#custom-image-preview')).toBeVisible();
  await page.locator('#custom-url').fill('ftp://example.com/v1');await page.locator('#custom-form [type="submit"]').click();
  await expect(page.locator('#custom-url-error')).toBeVisible();
  await page.locator('#custom-url').fill('http://localhost:8000/v1');
  await page.locator('#custom-form [type="submit"]').click();
  await expect(page.locator('#custom-list .endpoint-row')).toHaveCount(1);
  const payload=await page.evaluate(()=>settingsFixture.calls.filter(call=>call.cmd==='save_custom_endpoint').at(-1).args.endpoint);
  expect(payload).toMatchObject({unit:'tokens',monthly_budget_usd:20,current_spend_usd:0,monthly_budget_tokens_m:10,current_tokens_used_m:2.5,model:'local-a',health:'online',latency_ms:12});
  expect(payload.custom_icon_filename).toMatch(/\.png$/);
  expect(await page.evaluate(()=>settingsFixture.calls.some(call=>call.cmd==='test_custom_endpoint_draft'&&call.args.baseUrl==='http://localhost:8000/v1'))).toBe(true);
});

test('自定义端点编辑回填自有密钥，探测沿用密钥，清空后删除且保存失败不关闭草稿',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-custom').click();
  await page.locator('#custom-add').click();
  await page.locator('#custom-name').fill('Private endpoint');
  await page.locator('#custom-url').fill('https://example.com/v1?tenant=a#models');
  await page.locator('#custom-key').fill('fixture-custom-key');
  await page.locator('#custom-form [type="submit"]').click();
  await expect(page.locator('#custom-editor-wrap')).toBeHidden();
  const id=await page.evaluate(()=>settingsFixture.calls.find(c=>c.cmd==='save_custom_endpoint').args.endpoint.id);
  await page.locator('[data-custom-edit]').click();
  await expect(page.locator('#custom-key')).toHaveValue('fixture-custom-key');
  await page.locator('#custom-draft-probe').click();
  await expect(page.locator('#custom-draft-result')).toContainText('online');
  const probe=await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='test_custom_endpoint_draft').at(-1).args);
  expect(probe).toMatchObject({baseUrl:'https://example.com/v1?tenant=a#models',apiKey:'fixture-custom-key'});
  await page.evaluate(()=>{settingsFixture.customProbeResult={health:'unreachable',latency_ms:18,models:[],error:'The endpoint answered 401',status_code:401};});
  await page.locator('#custom-draft-probe').click();
  await expect(page.locator('#custom-draft-result')).toContainText('401');
  await page.locator('#custom-key').fill('');
  await page.evaluate(()=>{settingsFixture.failCustom=true;});
  await page.locator('#custom-form [type="submit"]').click();
  await expect(page.locator('#custom-editor-wrap')).toBeVisible();
  await expect(page.locator('#strip')).toContainText('fixture endpoint save refused');
  await page.evaluate(()=>{settingsFixture.failCustom=false;});
  await page.locator('#custom-form [type="submit"]').click();
  await expect(page.locator('#custom-editor-wrap')).toBeHidden();
  const saved=await page.evaluate(id=>settingsFixture.calls.filter(c=>c.cmd==='save_custom_endpoint'&&c.args.endpoint.id===id).at(-1).args.endpoint,id);
  expect(saved).toMatchObject({health:'unreachable',latency_ms:18,last_status_code:401,models:['local-a','local-b']});
  expect(await page.evaluate(id=>settingsFixture.customSecrets[id]??null,id)).toBeNull();
  expect(await page.evaluate(id=>settingsFixture.calls.some(c=>c.cmd==='save_provider_secret'&&c.args.id==='endpoint-'+id&&c.args.secret===''),id)).toBe(true);
});

test('取消上传后旧响应只清理旧图片，保存中取消不能丢失凭据',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-custom').click();
  await page.locator('#custom-add').click();
  const oldId=await page.locator('#custom-id').inputValue();
  await page.evaluate(()=>{settingsFixture.holdIcon=true;});
  const base64=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=2;canvas.height=2;return canvas.toDataURL('image/png').split(',')[1];});
  await page.locator('#custom-image-file').setInputFiles({name:'delayed.png',mimeType:'image/png',buffer:Buffer.from(base64,'base64')});
  await expect.poll(()=>page.evaluate(()=>settingsFixture.calls.some(c=>c.cmd==='save_custom_icon'))).toBe(true);
  await page.locator('#custom-cancel').click();
  await page.locator('#custom-add').click();
  const newId=await page.locator('#custom-id').inputValue();expect(newId).not.toBe(oldId);
  await page.evaluate(()=>{settingsFixture.holdIcon=false;settingsFixture.releaseIcon?.();});
  await expect.poll(()=>page.evaluate(id=>settingsFixture.calls.some(c=>c.cmd==='discard_custom_icon'&&c.args.filename?.startsWith(id)),oldId)).toBe(true);
  await expect(page.locator('#custom-image-preview')).toBeHidden();
  await page.locator('#custom-name').fill('Saved after cancellation');
  await page.locator('#custom-url').fill('http://localhost:8000/v1');
  await page.locator('#custom-key').fill('fixture-key-after-cancel');
  await page.evaluate(()=>{settingsFixture.holdCustomSecret=true;});
  await page.locator('#custom-form [type="submit"]').click();
  await expect.poll(()=>page.evaluate(id=>settingsFixture.calls.some(c=>c.cmd==='save_provider_secret'&&c.args.id==='endpoint-'+id),newId)).toBe(true);
  await expect(page.locator('#custom-cancel')).toBeDisabled();
  await page.evaluate(()=>{settingsFixture.holdCustomSecret=false;settingsFixture.releaseCustomSecret?.();});
  await expect(page.locator('#custom-editor-wrap')).toBeHidden();
  expect(await page.evaluate(id=>settingsFixture.customSecrets[id],newId)).toBe('fixture-key-after-cancel');
  const saved=await page.evaluate(id=>settingsFixture.calls.find(c=>c.cmd==='save_custom_endpoint'&&c.args.endpoint.id===id).args.endpoint,newId);
  expect(saved.custom_icon_filename).toBeNull();
});

test('移除已有图片时取消进行中的第二次上传并恢复保存',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-custom').click();
  await page.locator('#custom-add').click();
  const id=await page.locator('#custom-id').inputValue();
  const base64=await page.evaluate(()=>{const canvas=document.createElement('canvas');canvas.width=2;canvas.height=2;return canvas.toDataURL('image/png').split(',')[1];});
  const image={name:'icon.png',mimeType:'image/png',buffer:Buffer.from(base64,'base64')};
  await page.locator('#custom-image-file').setInputFiles(image);
  await expect(page.locator('#custom-image-preview')).toBeVisible();
  await page.evaluate(()=>{settingsFixture.holdIcon=true;});
  await page.locator('#custom-image-file').setInputFiles({...image,name:'icon-two.png'});
  await expect.poll(()=>page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='save_custom_icon').length)).toBe(2);
  await expect(page.locator('#custom-form [type="submit"]')).toBeDisabled();
  await page.locator('#custom-remove-image').click();
  await expect(page.locator('#custom-image-preview')).toBeHidden();
  await expect(page.locator('#custom-form [type="submit"]')).toBeEnabled();
  await page.locator('#custom-name').fill('Removed image');
  await page.locator('#custom-url').fill('http://localhost:8000/v1');
  await page.locator('#custom-form [type="submit"]').click();
  await expect(page.locator('#custom-editor-wrap')).toBeHidden();
  await page.evaluate(()=>{settingsFixture.holdIcon=false;settingsFixture.releaseIcon?.();});
  const stale=id+'-0000000000000002.png';
  await expect.poll(()=>page.evaluate(filename=>settingsFixture.calls.some(c=>c.cmd==='discard_custom_icon'&&c.args.filename===filename),stale)).toBe(true);
  const saved=await page.evaluate(id=>settingsFixture.calls.find(c=>c.cmd==='save_custom_endpoint'&&c.args.endpoint.id===id).args.endpoint,id);
  expect(saved.custom_icon_filename).toBeNull();
});

test('后台自定义端点探测事件更新列表而不覆盖正在编辑的草稿',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-custom').click();
  await page.locator('#custom-add').click();
  await page.locator('#custom-name').fill('Background endpoint');
  await page.locator('#custom-url').fill('http://localhost:8000/v1');
  await page.locator('#custom-form [type="submit"]').click();
  const id=await page.evaluate(()=>settingsFixture.calls.find(c=>c.cmd==='save_custom_endpoint').args.endpoint.id);
  await page.locator('[data-custom-edit]').click();
  await expect(page.locator('#custom-key')).toHaveValue('');
  await page.locator('#custom-name').fill('Unsaved editor name');
  await page.evaluate(id=>settingsFixture.backgroundCustomProbe(id,{health:'online',latency_ms:37,models:['model-x']}),id);
  await expect(page.locator('#custom-list')).toContainText('37 ms');
  await expect(page.locator('#custom-name')).toHaveValue('Unsaved editor name');
  await expect(page.locator('#custom-model')).toHaveJSProperty('tagName','INPUT');
});

test('本地运行时监控与地址检查走真实命令，失败保留原设置', async ({page}) => {
  await settingsBridge(page);
  await page.goto('/settings.html');
  await page.locator('#tab-ollama').click();
  await expect(page.locator('#ollama-monitor')).toHaveAttribute('aria-checked','false');
  await expect(page.locator('#ollama-status')).toHaveText('Monitoring off.');
  await page.evaluate(() => {settingsFixture.failLocal=true;});
  await page.locator('#ollama-monitor').click();
  await expect(page.locator('#strip')).toContainText('fixture monitor save refused');
  await expect(page.locator('#ollama-monitor')).toHaveAttribute('aria-checked','false');
  await page.evaluate(() => {settingsFixture.failLocal=false;});
  await page.locator('#ollama-monitor').click();
  await expect(page.locator('#ollama-monitor')).toHaveAttribute('aria-checked','true');
  await page.locator('#ollama-apply').click();
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.filter(c=>c.cmd==='refresh_ring').at(-1)?.args.provider)).toBe('ollama-local');
  await page.locator('#ollama-url').fill('http://127.0.0.1:11435');
  await expect(page.locator('#ollama-apply')).toHaveText('Apply');
  await page.evaluate(() => {settingsFixture.failLocal=true;});
  await page.locator('#ollama-apply').click();
  await expect(page.locator('#strip')).toContainText('fixture local settings save refused');
  await expect(page.locator('#ollama-url')).toHaveValue('http://127.0.0.1:11435');
  await page.evaluate(() => {settingsFixture.failLocal=false;});
  await page.locator('#ollama-apply').click();
  await expect(page.locator('#ollama-apply')).toHaveText('Check connection');
  expect(await page.evaluate(() => settingsFixture.calls.filter(c=>c.cmd==='set_local_runtime_settings').at(-1).args.prefs.ollama)).toBe('http://127.0.0.1:11435');
});

test('已加载本地模型只在 Accounts 有独立行，关闭模型不关闭父运行时',async({page})=>{
  // A nonempty saved selection appends newly loaded models. An explicit [] must stay empty.
  await settingsBridge(page,['ollama-local']);await page.goto('/settings.html');
  await page.locator('#tab-ollama').click();
  await expect(page.locator('#pane-ollama .sec')).toHaveText(['Connection']);
  await page.locator('#ollama-monitor').click();
  const model={id:'qwen3:8b',name:'qwen3:8b',key:'qwen3:8b',size:8*1024**3,size_kind:'memory',gpu_size:4*1024**3,context:32768,quantization:'Q4',expires_at:null,brand:'qwen'};
  await page.evaluate(model=>{
    settingsFixture.trayOptions=[{id:'ollama-local',label:'Ollama',status:'ok'},{id:'ollama-local:model:qwen3:8b',label:'qwen3:8b',status:'ok'}];
    settingsFixture.providerRows=[{id:'ollama-local',name:'Ollama',enabled:true,snap:{status:'ok'}},{id:'ollama-local:model:qwen3:8b',name:'qwen3:8b',enabled:true,snap:{status:'ok',local_model:model,source_provider_id:'ollama-local'}}];
    settingsFixture.emit('providers',settingsFixture.providerRows);
  },model);
  await page.locator('#tab-accounts').click();
  await expect(page.locator('[data-account="ollama-local:model:qwen3:8b"]')).toContainText('4 GB VRAM · via Ollama');
  // Swift's sidebar count includes the connected runtime account, not its model cells.
  await expect(page.locator('#account-count')).toHaveText('1');
  await page.locator('[data-account="ollama-local:model:qwen3:8b"] [data-np]').click();
  await expect(page.locator('[data-account="ollama-local:model:qwen3:8b"]')).toContainText('Hidden from the notch · Loaded in Ollama');
  await expect(page.locator('[data-account="ollama-local"] [data-np]')).toHaveAttribute('aria-checked','true');
  expect(await page.evaluate(()=>settingsFixture.calls.filter(call=>call.cmd==='set_provider_enabled').at(-1).args)).toEqual({id:'ollama-local:model:qwen3:8b',value:false});
});

test('Ollama 速度与思考开关只在连接后可用，持久化失败回滚并显示真实 relay 状态',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-ollama').click();
  await expect(page.locator('#ollama-metrics')).toBeDisabled();
  await page.locator('#ollama-monitor').click();
  await expect(page.locator('#ollama-metrics')).toBeEnabled();
  await page.evaluate(()=>{settingsFixture.failLocal=true;});
  await page.locator('#ollama-metrics').click();
  await expect(page.locator('#strip')).toContainText('fixture local settings save refused');
  await expect(page.locator('#ollama-metrics')).toHaveAttribute('aria-checked','false');
  await page.evaluate(()=>{settingsFixture.failLocal=false;});
  await page.locator('#ollama-metrics').click();
  await expect(page.locator('#ollama-metrics')).toHaveAttribute('aria-checked','true');
  await expect(page.locator('#ollama-relay')).toContainText('Listening at http://127.0.0.1:11435');
  await expect(page.locator('#ollama-relay')).toContainText('1 model(s)');
  await expect(page.locator('#ollama-relay code')).toHaveText('OLLAMA_HOST=http://127.0.0.1:11435 ollama');
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_local_runtime_settings').at(-1).args.prefs.ollama_metrics_enabled)).toBe(true);
});

test('LM Studio token 只通过自有凭据库保存移除，失败保留输入与旧状态',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-lmstudio').click();
  await expect(page.locator('#lmstudio-token-hint')).toContainText('Only needed when LM Studio');
  await expect(page.locator('#lmstudio-token-remove')).toBeHidden();
  await page.locator('#lmstudio-token').fill('fixture-token');
  await page.evaluate(()=>{settingsFixture.failLMToken=true;});
  await page.locator('#lmstudio-token-save').click();
  await expect(page.locator('#strip')).toContainText('fixture token vault refused');
  await expect(page.locator('#lmstudio-token')).toHaveValue('fixture-token');
  await page.evaluate(()=>{settingsFixture.failLMToken=false;});
  await page.locator('#lmstudio-token-save').click();
  await expect(page.locator('#lmstudio-token')).toHaveValue('');
  await expect(page.locator('#lmstudio-token-remove')).toBeVisible();
  await expect(page.locator('#lmstudio-token-hint')).toContainText('A token is stored');
  await page.locator('#lmstudio-token-remove').click();
  await expect(page.locator('#lmstudio-token-remove')).toBeHidden();
  expect(await page.evaluate(()=>settingsFixture.calls.filter(call=>call.cmd==='save_provider_secret'&&call.args.id==='lmstudio-api-token').map(call=>call.args.secret))).toEqual(['fixture-token','fixture-token','']);
});

test('外观设置真实调用保存，失败时显示原持久值', async ({page}) => {
  await settingsBridge(page);
  await page.goto('/settings.html');
  await page.locator('#tab-appearance').click();
  await page.evaluate(() => { settingsFixture.failAppearance = true; });
  await page.locator('#seg-reset_time [data-v="remaining"]').click();
  await expect(page.locator('#strip')).toContainText('fixture appearance save refused');
  await expect(page.locator('#seg-reset_time [aria-pressed="true"]')).toHaveAttribute('data-v','automatic');
  await page.evaluate(() => { settingsFixture.failAppearance = false; });
  await page.locator('#seg-reset_time [data-v="remaining"]').click();
  await expect(page.locator('#seg-reset_time [aria-pressed="true"]')).toHaveAttribute('data-v','remaining');
  await expect(page.locator('#cap-reset_time')).toContainText('Time until usage resets');
  await page.locator('#seg-size-mode [data-v="custom"]').click();
  await expect(page.locator('#custom-size-controls')).toBeVisible();
  await page.locator('#appearance-custom_scale').evaluate(el => { el.value = '1.15'; el.dispatchEvent(new Event('change', {bubbles:true})); });
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.filter(c => c.cmd === 'set_appearance').at(-1)?.args.prefs.custom_scale)).toBe(1.15);
  await page.locator('#appearance-reset_limits').click();
  const saved = await page.evaluate(() => settingsFixture.calls.filter(c => c.cmd === 'set_appearance').at(-1).args.prefs);
  expect(saved).toMatchObject({reset_time:'remaining', custom_scale:1.15, watch:.5, critical:.7});
  await page.locator('#seg-weekly [data-v="inside"]').click();
  await expect(page.locator('#row-weekly_dashed')).toBeVisible();
});

test('通知持续时间分段保存失败回滚，更新消息优先于可安装版本', async ({page}) => {
  await settingsBridge(page);
  await page.setViewportSize({width:860, height:600});
  await page.goto('/settings.html');
  await page.locator('#tab-notifications').click();
  await expect(page.locator('#pane-notifications .sound-preview')).toHaveCount(4);
  await expect(page.locator('#pane-notifications .cap.tertiary')).toContainText('The sound plays on the ordinary output');
  await expect(page.locator('#pane-notifications .group').first()).toContainText('Velo already knows the moment an agent stops working');
  await expect(page.locator('#pane-notifications .group').nth(1)).toContainText("Displays a notification card from the side of the notch when a provider's session or weekly usage limit is reached.");
  await expect(page.locator('#pane-notifications .group').nth(2)).toContainText("Displays a notification card from the side of the notch when a provider's usage limit resets.");
  await expect(page.locator('#pane-notifications .group').nth(3)).toContainText("again only after the window rolls over");
  const picker = await page.locator('#notification-finished_sound').boundingBox();
  const preview = await page.locator('[data-preview-sound="finished_sound"]').boundingBox();
  expect(picker.x).toBeGreaterThan(680);
  expect(preview.x).toBeGreaterThan(picker.x + picker.width - 1);
  await page.locator('[data-preview-sound="finished_sound"]').click();
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.some(c => c.cmd === 'preview_alert_sound' && c.args.name === 'Glass'))).toBe(true);
  await expect(page.locator('#seg-peek_seconds [aria-pressed="true"]')).toHaveAttribute('data-v','5');
  await page.evaluate(() => { settingsFixture.failNotifications = true; });
  await page.locator('#seg-peek_seconds [data-v="10"]').click();
  await expect(page.locator('#strip')).toContainText('fixture notification save refused');
  await expect(page.locator('#seg-peek_seconds [aria-pressed="true"]')).toHaveAttribute('data-v','5');
  await page.evaluate(() => { settingsFixture.failNotifications = false; });
  await page.locator('#seg-peek_seconds [data-v="3"]').click();
  await expect(page.locator('#seg-peek_seconds [aria-pressed="true"]')).toHaveAttribute('data-v','3');
  expect(await page.evaluate(() => settingsFixture.calls.filter(c => c.cmd === 'set_notifications').at(-1).args.prefs.peek_seconds)).toBe(3);
  await page.locator('#tab-general').click();
  await page.evaluate(() => settingsFixture.update({available:'1.17.0',message:'Could not install the update'}));
  await expect(page.locator('#update-status')).toHaveText('Could not install the update');
  await expect(page.locator('#btn-update')).toHaveText('Update');
  await page.locator('#btn-update').click();
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.some(c => c.cmd === 'install_update'))).toBe(true);
  await page.evaluate(() => settingsFixture.update({available:null,message:'Update installed; restart the app to finish'}));
  await expect(page.locator('#update-status')).toHaveText('Update installed; restart the app to finish');
  await expect(page.locator('#btn-update')).toHaveText('Check now');
  await page.evaluate(() => settingsFixture.update({available:'1.18.0',staged:'1.18.0',message:'This copy cannot be updated silently. Install Velo in a writable Applications folder or choose Install.'}));
  await expect(page.locator('#update-status')).toHaveText('This copy cannot be updated silently. Install Velo in a writable Applications folder or choose Install.');
  await page.evaluate(() => settingsFixture.update({message:'Update downloaded and will install when Velo next launches.'}));
  await expect(page.locator('#update-status')).toHaveText('Version 1.18.0. Updates install in the background and apply next time Velo starts.');
  await expect(page.locator('#btn-update')).toHaveText('Update');
  await page.evaluate(() => settingsFixture.update({message:null}));
  await expect(page.locator('#update-status')).toHaveText('Version 1.18.0. Updates install in the background and apply next time Velo starts.');
  await page.evaluate(() => settingsFixture.update({available:null,staged:null,up_to_date:true,last_checked_ms:Date.UTC(2026,8,23,12,34)}));
  const checked=await page.evaluate(()=>new Intl.DateTimeFormat('en-US',{dateStyle:'short',timeStyle:'short'}).format(new Date(Date.UTC(2026,8,23,12,34))));
  await expect(page.locator('#update-status')).toHaveText('Velo is up to date. · '+checked);
  await page.locator('#tab-appearance').click();
  await page.locator('#lang').selectOption('fr');
  await page.locator('#tab-general').click();
  await page.evaluate(() => settingsFixture.update({up_to_date:false,staged:'1.18.0',message:'Update downloaded and will install when Velo next launches.'}));
  await expect(page.locator('#update-status')).toHaveText("Version 1.18.0. Les mises à jour s'installent en arrière-plan et s'appliquent au prochain démarrage de Velo.");
});

test('有无滚动条时分组右缘均保持 20pt 内边距', async ({page}) => {
  await settingsBridge(page);
  await page.setViewportSize({width:860, height:600});
  await page.goto('/settings.html');
  const layout = () => page.evaluate(() => {
    const body=document.getElementById('body');
    const pane=document.querySelector('.pane:not([hidden])');
    const group=pane.querySelector('.group');
    return {
      gap:body.getBoundingClientRect().right-group.getBoundingClientRect().right,
      overflowing:body.scrollHeight>body.clientHeight,
      gutter:body.offsetWidth-body.clientWidth,
      applied:Number.parseFloat(body.style.getPropertyValue('--body-scrollbar-gutter'))
    };
  });
  await page.locator('#tab-general').click();
  await expect.poll(async () => (await layout()).overflowing).toBe(false);
  await expect.poll(async () => (await layout()).gap).toBeCloseTo(20, 0);
  await page.locator('#tab-notifications').click();
  await expect.poll(async () => (await layout()).overflowing).toBe(true);
  await expect.poll(async () => (await layout()).gap).toBeCloseTo(20, 0);
  await expect.poll(async () => { const {gutter,applied}=await layout(); return applied===gutter; }).toBe(true);
  await page.locator('#tab-general').click();
  await expect.poll(async () => (await layout()).gap).toBeCloseTo(20, 0);
});

test('原版完整语言选项保存 raw value 并使用固定 catalog 翻译', async ({page}) => {
  await settingsBridge(page);
  await page.goto('/settings.html');
  await page.locator('#tab-appearance').click();
  await expect(page.locator('#lang option')).toHaveCount(12);
  for(const [raw,title,caption] of [
    ['fr','Langue','Codenotch utilise cette langue même si le Mac ne le fait pas.'],
    ['de','Sprache','Codenotch verwendet diese Sprache, auch wenn der Mac es nicht tut.'],
    ['uz','Til','Mac boshqa tilda boʻlsa ham, Codenotch shu tildan foydalanadi.']
  ]){
    await page.locator('#lang').selectOption(raw);
    await expect(page.locator('#lang')).toHaveValue(raw);
    await expect(page.locator('#pane-appearance')).toContainText(title);
    await expect(page.locator('#language-explanation')).toHaveText(caption.replaceAll('Codenotch','Velo'));
    expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_lang').at(-1)?.args.lang)).toBe(raw);
  }
  await page.locator('#lang').selectOption('zh-Hans');
  await expect(page.locator('html')).toHaveAttribute('lang','zh-Hans');
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_lang').at(-1)?.args.lang)).toBe('zh-Hans');
});

test('设置切页在减少动态效果下仍按原版纯透明度 0.12 秒过渡', async ({page}) => {
  await settingsBridge(page);
  await page.emulateMedia({reducedMotion:'reduce'});
  await page.goto('/settings.html');
  await page.locator('#tab-appearance').click();
  const animation=await page.locator('#pane-appearance').evaluate(el=>{
    const style=getComputedStyle(el);
    return {name:style.animationName,duration:style.animationDuration};
  });
  expect(animation).toEqual({name:'pane-fade-in',duration:'0.12s'});
});

test('原版连续尺寸与阈值滑杆串行保存最新值，失败回滚到最近成功值', async ({page}) => {
  await settingsBridge(page);
  await page.goto('/settings.html');
  await page.locator('#tab-appearance').click();
  await page.locator('#seg-size-mode [data-v="custom"]').click();
  await expect(page.locator('#appearance-custom_scale')).toBeEnabled();
  await page.evaluate(() => { settingsFixture.holdAppearance=true; });
  for(const value of ['1.05','1.10','1.15']) {
    await page.locator('#appearance-custom_scale').evaluate((el,value) => {
      el.value=value;el.dispatchEvent(new Event('input',{bubbles:true}));
    },value);
  }
  await expect(page.locator('#appearance-scale_value')).toHaveText('115%');
  await expect.poll(() => page.evaluate(() => settingsFixture.appearanceInFlight)).toBe(1);
  await page.evaluate(() => { settingsFixture.holdAppearance=false;settingsFixture.releaseAppearance(); });
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1)?.args.prefs.custom_scale)).toBe(1.15);
  await expect.poll(() => page.evaluate(() => settingsFixture.appearanceInFlight)).toBe(0);
  expect(await page.evaluate(() => settingsFixture.maxAppearanceInFlight)).toBe(1);
  await expect(page.locator('#appearance-custom_scale')).toHaveValue('1.15');
  await page.evaluate(() => { settingsFixture.failAppearance=true; });
  await page.locator('#appearance-custom_scale').evaluate(el => {el.value='1.25';el.dispatchEvent(new Event('input',{bubbles:true}));});
  await expect(page.locator('#strip')).toContainText('fixture appearance save refused');
  await expect(page.locator('#appearance-custom_scale')).toHaveValue('1.15');
  await page.evaluate(() => { settingsFixture.failAppearance=false; });
  await page.locator('#appearance-watch').evaluate(el => {el.value='60';el.dispatchEvent(new Event('input',{bubbles:true}));});
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1)?.args.prefs.watch)).toBe(.6);
  await page.locator('#appearance-critical').evaluate(el => {el.value='80';el.dispatchEvent(new Event('input',{bubbles:true}));});
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1)?.args.prefs.critical)).toBe(.8);
  await page.locator('#appearance-watch').evaluate(el => {el.value='50.5';el.dispatchEvent(new Event('input',{bubbles:true}));});
  await expect.poll(() => page.evaluate(() => settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1)?.args.prefs.watch)).toBe(.505);
  await expect(page.locator('#appearance-watch')).toHaveValue('50.5');
});

test('新进程的设置默认打开 Accounts，同一窗口再次前置保留当前页',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');
  await page.locator('#tab-general').click();
  await page.evaluate(()=>settingsFixture.emit('settings_opened'));
  await expect(page.locator('#pane-general')).toBeVisible();
  // Reload reconstructs SettingsView; its selection state starts at Accounts.
  await page.reload();
  await expect(page.locator('#pane-accounts')).toBeVisible();
});

test('原生版本 API 同步侧栏与通用页，失踪的已选音效保留标记', async ({page}) => {
  await settingsBridge(page, [], '1.1.0-preview.1', 'Removed Bell');
  await page.goto('/settings.html');
  await expect(page.locator('#side-version')).toHaveText('1.1.0-preview.1');
  await page.locator('#tab-general').click();
  await expect(page.locator('#about-version-copy')).toHaveText('Version 1.1.0-preview.1. Updates install in the background and apply next time Velo starts.');
  await page.locator('#tab-notifications').click();
  await expect(page.locator('#notification-finished_sound option:checked')).toHaveText('Removed Bell (missing)');
  await expect(page.locator('#notification-finished_sound')).toHaveValue('Removed Bell');
});

test('Accounts 首次连接说明、空组和顺序说明随真实元数据及窗口重开更新',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');
  await expect(page.locator('#acc-on')).toContainText('Connect an assistant to get started');
  await expect(page.locator('#acc-on')).toContainText('Nothing is connected, so the notch has no rings to draw.');
  await expect(page.locator('#acc-on')).toContainText('DeepSeek and MiniMax are the exceptions');
  await page.evaluate(()=>{
    settingsFixture.providerRows=[{id:'claude',name:'Claude',enabled:true,account:{label:'work',source:'Claude Code'},snap:{status:'ok'}}];
    settingsFixture.emit('settings_opened',null);
  });
  await expect(page.locator('.setup-note')).toHaveCount(0);
  await page.evaluate(()=>{settingsFixture.trayOptions=[{id:'claude',label:'Claude',status:'ok'}];notchSlots=[{provider:'claude'}];refreshOptions();});
  await expect(page.locator('#acc-on')).toContainText('The notch draws these in this order.');
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='get_providers').length)).toBeGreaterThan(1);
});

test('settings_opened 重读账户时保留尚未保存的密钥草稿',async({page})=>{
  await settingsBridge(page,['minimax']);await page.goto('/settings.html');
  await page.evaluate(()=>{
    settingsFixture.trayOptions=[{id:'minimax',label:'MiniMax',status:'needsAuth'}];
    settingsFixture.providerRows=[{id:'minimax',name:'MiniMax',enabled:true,account:null,snap:{status:'needsAuth'}}];
    settingsFixture.emit('providers',settingsFixture.providerRows);
    refreshOptions();
  });
  const draft=page.locator('[data-account="minimax"] input[data-key="minimax"]');
  await draft.fill('fixture-unsaved-key');
  await page.evaluate(()=>{settingsFixture.providerRows=[{...settingsFixture.providerRows[0],guidance:'Sign in needed'}];settingsFixture.emit('settings_opened',null);});
  await expect(draft).toHaveValue('fixture-unsaved-key');
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='save_provider_secret'&&c.args?.id==='minimax'))).toHaveLength(0);
});

test('本地 Open 不依赖监控开关，Check 只按真实接受和检查状态运行',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');
  await page.locator('#tab-ollama').click();
  await expect(page.locator('#ollama-apply')).toBeDisabled();
  await page.evaluate(()=>{settingsFixture.destinations['ollama-local']={kind:'app',label:'Ollama',help:''};});
  await page.locator('#ollama-open').click();
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='open_account_destination').at(-1)?.args)).toEqual({id:'ollama-local'});
  await page.locator('#ollama-monitor').click();
  await expect(page.locator('#ollama-apply')).toBeEnabled();
  await page.evaluate(()=>{settingsFixture.refreshAccepted=false;});
  await page.locator('#ollama-apply').click();
  await expect(page.locator('#ollama-apply')).toBeEnabled();
  await page.evaluate(()=>{settingsFixture.refreshAccepted=true;settingsFixture.localActivity.checking['ollama-local']=true;});
  await page.locator('#ollama-apply').click();
  await expect(page.locator('#ollama-apply')).toBeDisabled();
  await expect(page.locator('#ollama-status')).toContainText('Checking Ollama…');
});

test('LM Studio 的真实状态、历史和 token 数在连接后可见',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');
  await page.locator('#tab-lmstudio').click();
  await expect(page.locator('#lmstudio-activity')).toBeVisible();
  await page.locator('#lmstudio-monitor').click();
  await expect(page.locator('#lmstudio-activity')).toBeHidden();
  await page.locator('#lmstudio-monitor').click();
  await expect(page.locator('#lmstudio-activity')).toContainText("Reading LM Studio's server log…");
  await page.evaluate(()=>{
    settingsFixture.localActivity.lmstudio={status:'Linked to LM Studio',linked:true,history_loaded:true,
      today:{requests:2,input_tokens:12345,output_tokens:1500000},model_count:1};
    refreshLocalActivity();
  });
  await expect(page.locator('#lmstudio-activity')).toContainText('Linked to LM Studio');
  await expect(page.locator('#lmstudio-activity')).toContainText('Today: 2 requests · 12k tokens in · 1.5M out');
  await page.evaluate(()=>{settingsFixture.destinations.lmstudio={kind:'app',label:'LM Studio',help:''};});
  await page.locator('#lmstudio-open').click();
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='open_account_destination').at(-1)?.args)).toEqual({id:'lmstudio'});
});

test('断开的已选显示器仍保留选项，重连事件立即刷新',async({page})=>{
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-appearance').click();
  await page.evaluate(()=>{
    settingsFixture.monitors=[{id:'old-screen',label:'Unavailable display',primary:false,current:false,pinned:true,unavailable:true}];
    settingsFixture.emit('monitors_changed',null);
  });
  await expect(page.locator('#screen')).toHaveValue('old-screen');
  await expect(page.locator('#screen option:checked')).toHaveText('Unavailable display');
  await expect(page.locator('#cap-screen')).toContainText('That display is disconnected.');
  await page.evaluate(()=>{
    settingsFixture.monitors=[{id:'old-screen',label:'2  2560 × 1440',primary:false,current:true,pinned:true,unavailable:false}];
    settingsFixture.emit('monitors_changed',null);
  });
  await expect(page.locator('#screen')).toHaveValue('old-screen');
  await expect(page.locator('#cap-screen')).toContainText('Pinned to 2  2560 × 1440.');
});

test('Windows App icon 三态使用任务栏和托盘文案',async({page})=>{
  await page.addInitScript(()=>Object.defineProperty(navigator,'platform',{get:()=> 'Win32'}));
  await settingsBridge(page);await page.goto('/settings.html');await page.locator('#tab-appearance').click();
  await expect(page.locator('#app-presence-controls')).toBeVisible();
  await expect(page.locator('#seg-presence [data-v="dock"]')).toHaveText('Taskbar');
  await expect(page.locator('#seg-presence [data-v="menuBar"]')).toHaveText('System tray');
  await page.locator('#seg-presence [data-v="hidden"]').click();
  await expect(page.locator('#cap-presence')).toContainText('Start menu');
  expect(await page.evaluate(()=>settingsFixture.calls.filter(c=>c.cmd==='set_appearance').at(-1)?.args.prefs.app_presence)).toBe('hidden');
});
