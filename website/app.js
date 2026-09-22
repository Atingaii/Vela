const root=document.documentElement;
const themeButton=document.getElementById('theme');
let theme='light';
try{theme=localStorage.getItem('velo-theme')||'light';}catch{}
function applyTheme(value){
  theme=value==='dark'?'dark':'light';root.dataset.theme=theme;
  themeButton.setAttribute('aria-label',theme==='dark'?'切换到浅色模式':'切换到深色模式');
  themeButton.setAttribute('aria-pressed',String(theme==='dark'));
}
applyTheme(theme);
themeButton.addEventListener('click',()=>{applyTheme(theme==='dark'?'light':'dark');try{localStorage.setItem('velo-theme',theme);}catch{}});
