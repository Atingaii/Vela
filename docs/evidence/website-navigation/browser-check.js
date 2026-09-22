async(page)=>{
 const base='https://velo.codes';const errors=[];page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')errors.push(m.text());});
 await page.goto(base);await page.evaluate(()=>localStorage.setItem('velo-theme','light'));await page.reload();
 const checks=[];
 for(const route of ['/','/download/','/guide/']){
  await page.goto(base+route);await page.evaluate(()=>document.fonts.ready);
  for(const width of [1440,390,320]){
   await page.setViewportSize({width,height:960});
   await page.evaluate(()=>Promise.all([...document.images].map(i=>i.decode())));
   const result=await page.evaluate(()=>({path:location.pathname,width:innerWidth,scroll:document.documentElement.scrollWidth,h1:document.querySelectorAll('h1').length,broken:[...document.images].filter(i=>!i.complete||!i.naturalWidth).length,nav:[...document.querySelectorAll('header a')].map(a=>a.getAttribute('href')),current:document.querySelector('header [aria-current=page]')?.getAttribute('href')||null,icons:[...document.querySelectorAll('link[rel=icon]')].map(i=>i.href)}));
   if(result.width!==result.scroll||result.h1!==1||result.broken||result.nav.some(h=>h.startsWith('#')))throw new Error(JSON.stringify(result));
   if(route!=='/'&&result.current!==route)throw new Error('Current page missing');
   checks.push(result);
   await page.evaluate(()=>scrollTo(0,0));await page.screenshot({path:`output/playwright/velo-nav/${route==='/'?'home':route.split('/')[1]}-${width}.png`,fullPage:width===390});
  }
 }
 await page.goto(base);await page.setViewportSize({width:1440,height:960});
 await page.getByRole('button',{name:'查看 Codex 示例额度 62%',exact:true}).hover();
 if(await page.locator('#demo-name').textContent()!=='Codex'||await page.locator('.demo-meter').getAttribute('aria-valuenow')!=='62')throw new Error('Hover failed');await page.locator('.demo-meter').evaluate(async e=>{await Promise.all(e.firstElementChild.getAnimations().map(a=>a.finished));});const fill=await page.locator('.demo-meter').evaluate(e=>e.firstElementChild.getBoundingClientRect().width/e.getBoundingClientRect().width);if(Math.abs(fill-.62)>.015)throw new Error('Meter width/CSP mismatch '+fill);
 await page.getByRole('button',{name:'查看 Cursor 示例额度 19%',exact:true}).focus();
 if(await page.locator('#demo-task').textContent()!=='任务完成，可以继续了')throw new Error('Focus failed');
 await page.setViewportSize({width:320,height:800});await page.getByRole('button',{name:'查看 Claude 示例额度 38%',exact:true}).click();
 if(await page.locator('#demo-name').textContent()!=='Claude')throw new Error('Mobile click failed');
 await page.getByRole('button',{name:'切换到深色模式'}).click();
 await page.getByRole('navigation',{name:'主导航',exact:true}).getByRole('link',{name:'下载 Velo'}).click();
 await page.waitForURL(base+'/download/');await page.waitForFunction(()=>document.documentElement.dataset.theme==='dark');
 if(!page.url().endsWith('/download/')||await page.locator('html').getAttribute('data-theme')!=='dark')throw new Error('Download route/theme failed');
 await page.getByRole('navigation',{name:'主导航',exact:true}).getByRole('link',{name:'使用指南'}).click();
 await page.waitForURL(base+'/guide/');
 if(!page.url().endsWith('/guide/'))throw new Error('Guide route failed');
 await page.getByText('第一次使用，需要做什么？',{exact:true}).click();
 if(!await page.getByText('第一次使用，需要做什么？',{exact:true}).evaluate(e=>e.parentElement.open))throw new Error('FAQ failed');
 await page.getByRole('link',{name:'Velo 首页',exact:true}).click();await page.waitForURL(base+'/');await page.waitForLoadState('domcontentloaded');
 await page.setViewportSize({width:1440,height:960});await page.evaluate(()=>scrollTo(0,0));await page.screenshot({path:'output/playwright/velo-nav/home-dark.png'});
 await page.getByRole('button',{name:'切换到浅色模式'}).click();
 for(const [hash,destination] of [['#download','/download/'],['#faq','/guide/#faq']]){await page.goto(base+'/'+hash);await page.waitForURL(base+destination);}
 await page.goto(base);await page.keyboard.press('Tab');
 const first=await page.evaluate(()=>document.activeElement.textContent.trim());if(first!=='跳到正文')throw new Error('Skip link not first: '+first);
 await page.keyboard.press('Enter');if(!page.url().endsWith('#main'))throw new Error('Skip failed');
 if(errors.length)throw new Error(JSON.stringify(errors));
 return {checks,interactions:'hover, focus, mobile click, real navigation, FAQ, theme persistence, legacy hashes, keyboard skip: passed',errors};
}
