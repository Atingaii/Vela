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

// Original image links still work without JavaScript; the dialog adds in-page zoom.
const imageLinks=[...document.querySelectorAll('[data-lightbox]')];
if(imageLinks.length){
 const viewer=document.createElement('dialog');viewer.className='screenshot-viewer';viewer.setAttribute('aria-labelledby','viewer-title');
 const bar=document.createElement('div');bar.className='viewer-toolbar';
 const title=document.createElement('h2');title.id='viewer-title';
 const original=document.createElement('a');original.textContent='打开原图 ↗';original.target='_blank';original.rel='noopener';
 const close=document.createElement('button');close.type='button';close.textContent='×';close.setAttribute('aria-label','关闭截图');
 const scroll=document.createElement('div');scroll.className='viewer-scroll';scroll.tabIndex=0;scroll.setAttribute('aria-label','高清截图，可滚动查看细节');
 const image=document.createElement('img');scroll.append(image);bar.append(title,original,close);viewer.append(bar,scroll);document.body.append(viewer);
 close.addEventListener('click',()=>viewer.close());
 viewer.addEventListener('click',e=>{if(e.target===viewer)viewer.close();});
 viewer.addEventListener('close',()=>root.classList.remove('viewer-open'));
 for(const link of imageLinks)link.addEventListener('click',e=>{
  if(e.ctrlKey||e.metaKey||e.shiftKey||e.altKey)return;
  e.preventDefault();const source=link.querySelector('img');title.textContent=source.alt;image.src=source.src;image.alt=source.alt;image.dataset.wide=String(source.width>600||source.naturalWidth>1000);original.href=link.href;
  viewer.showModal();root.classList.add('viewer-open');scroll.scrollTop=0;scroll.scrollLeft=0;close.focus();
 });
}

// Keep the download as an ordinary file link; show the next steps, not fake progress.
const downloadNext=document.getElementById('download-next');
if(downloadNext){
 for(const link of document.querySelectorAll('[data-download-platform="macos"]'))link.addEventListener('click',()=>{
  downloadNext.hidden=false;downloadNext.focus({preventScroll:true});downloadNext.scrollIntoView({block:'center',behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth'});
 });
}
