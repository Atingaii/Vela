// README screenshots only. Never loaded by the application. All data is synthetic.
(() => {
  const now = Date.now();
  const listeners = {};
  const snapshots = {
    claude: {status:'ok',plan:'Max',fetched_at:now,windows:[
      {id:'session',label:'Session',used:.38,resets_at:now+7200000},
      {id:'seven_day',label:'Weekly',used:.24,resets_at:now+259200000}]},
    codex: {status:'ok',plan:'Plus',fetched_at:now,windows:[
      {id:'primary',label:'5-hour',used:.62,resets_at:now+10800000},
      {id:'secondary',label:'Weekly',used:.41,resets_at:now+345600000}]},
    cursor: {status:'ok',plan:'Pro',fetched_at:now,windows:[
      {id:'included',label:'Included usage',used:.19,resets_at:now+864000000}]},
  };
  const appearance = {reset_time:'remaining',show_codex_extra:true,show_usage_pace:false,
    claude_daily_pace:false,folds_for_fullscreen:true,weekly_dashed:false,
    custom_scale:null,watch:.5,critical:.7};
  window.__README_DEMO__ = true;
  window.__TAURI__ = {
    core:{invoke:async(cmd)=>{
      if(cmd==='get_usage')return snapshots.claude;
      if(cmd==='get_codex')return snapshots.codex;
      if(cmd==='get_cursor')return snapshots.cursor;
      if(['get_grok','get_antigravity','get_glm'].includes(cmd))return {status:'absent',windows:[]};
      if(cmd==='get_notch_slots')return ['claude','codex','cursor'].map(provider=>({provider}));
      if(cmd==='get_tray_options')return [{id:'claude',label:'Claude',status:'ok'},{id:'codex',label:'Codex',status:'ok'},{id:'cursor',label:'Cursor',status:'ok'}];
      if(cmd==='get_providers')return [];
      if(cmd==='get_state')return {sessions:[{id:'demo-session',title:'vela-demo',state:'running',started:now-60000,total:0,last:'Read',attn:'',prompt:'整理项目文档',model:''}],agg:'running',lang_resolved:'zh',clock_24h:true};
      if(cmd==='get_activity')return [{id:'demo-session',provider:'claude',state:'busy',name:'vela-demo',detail:'Working',since:now-60000}];
      if(cmd==='get_lang'||cmd==='get_lang_resolved')return 'zh';
      if(cmd==='get_scale')return 1;
      if(cmd==='get_notch_edge')return 'right';
      if(cmd==='get_weekly_ring')return 'outside';
      if(cmd==='get_ui_flags')return {notch_visible:true,tray_visible:true,notch_on_hover:false};
      if(cmd==='get_appearance')return appearance;
      if(cmd==='get_system_look')return {mica:false,accent:[]};
      if(cmd==='get_update_state')return {configured:false,status:'idle'};
      if(cmd==='get_notifications')return {attention:false,done:false};
      if(cmd==='get_autostart')return false;
      if(cmd==='get_hooks_installed'||cmd==='get_move_handle')return true;
      if(cmd==='get_disabled_providers'||cmd==='get_custom_endpoints'||cmd==='get_monitors')return [];
      if(cmd==='get_provider_settings')return {minimax_china:false};
      if(cmd==='get_alert_sounds')return ['Glass','Funk','Ping'];
      if(cmd==='get_phone_link')return {enabled:false,port:8788,hosts:[],devices:[]};
      if(cmd==='get_glyphs')return window.__README_GLYPHS__ || {};
      return null;
    }},
    app:{getVersion:async()=>'0.1.0'},
    event:{listen:async(name,cb)=>{(listeners[name]??=[]).push(cb);return ()=>{};}},
    window:{getCurrentWindow:()=>({close:async()=>{},startDragging:async()=>{}})},
    webview:{getCurrentWebview:()=>({onDragDropEvent:async()=>()=>{}})},
  };
})();
