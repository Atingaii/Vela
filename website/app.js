const root=document.documentElement;
const themeButton=document.getElementById('theme');
let theme='light';
try{theme=localStorage.getItem('velo-theme')||'light';}catch{}
function applyTheme(value){
  theme=value==='dark'?'dark':'light';root.dataset.theme=theme;
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content',theme==='dark'?'#0c0c12':'#fcfcfd');
  themeButton.setAttribute('aria-label',theme==='dark'?'切换到浅色模式':'切换到深色模式');
  themeButton.setAttribute('aria-pressed',String(theme==='dark'));
}
applyTheme(theme);
themeButton.addEventListener('click',()=>{applyTheme(theme==='dark'?'light':'dark');try{localStorage.setItem('velo-theme',theme);}catch{}});

// Keep old bookmarked sections useful after splitting the site into real pages.
const legacySections={'#download':'/download/','#faq':'/guide/#faq'};
function redirectLegacySection(){
  if(location.pathname==='/' && legacySections[location.hash])location.replace(legacySections[location.hash]);
}
redirectLegacySection();
window.addEventListener('hashchange',redirectLegacySection);

const examples={
  claude:{name:'Claude',used:38,status:'运行中',period:'当前会话',reset:'2 小时后重置',task:'正在处理你的任务'},
  codex:{name:'Codex',used:62,status:'等待回应',period:'短期窗口',reset:'3 小时后重置',task:'有一步需要你确认'},
  cursor:{name:'Cursor',used:19,status:'已完成',period:'当前周期',reset:'12 天后重置',task:'任务完成，可以继续了'}
};
const demoTools=[...document.querySelectorAll('[data-tool]')];
function showExample(key){
  const value=examples[key];if(!value)return;
  for(const button of demoTools){const selected=button.dataset.tool===key;button.classList.toggle('is-selected',selected);button.setAttribute('aria-pressed',String(selected));}
  for(const [id,text] of Object.entries({'demo-name':value.name,'demo-used':`${value.used}%`,'demo-status':value.status,'demo-period':value.period,'demo-reset':value.reset,'demo-task':value.task}))document.getElementById(id).textContent=text;
  const meter=document.querySelector('.demo-meter');meter.setAttribute('aria-valuenow',String(value.used));meter.setAttribute('aria-label',`${value.name} 示例已用额度`);meter.firstElementChild.style.width=`${value.used}%`;
}
for(const button of demoTools){for(const event of ['mouseenter','focus','click'])button.addEventListener(event,()=>showExample(button.dataset.tool));}
