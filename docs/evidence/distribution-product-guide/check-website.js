async(page)=>{
 const base='https://velo.codes',errors=[],checks=[];
 page.on('pageerror',e=>errors.push(e.message));page.on('console',m=>{if(m.type()==='error')errors.push(m.text())});
 await page.goto(base);await page.evaluate(()=>localStorage.setItem('velo-theme','light'));await page.reload();
 for(const route of ['/','/product/','/guide/','/download/']){
  await page.goto(base+route);await page.evaluate(()=>{for(const i of document.images)i.loading='eager';return document.fonts.ready;});
  for(const width of [1440,390,320]){
   await page.setViewportSize({width,height:960});await page.evaluate(()=>Promise.all([...document.images].filter(i=>i.hasAttribute("src")).map(i=>i.decode())));
   const state=await page.evaluate(()=>({route:location.pathname,width:innerWidth,scrollWidth:document.documentElement.scrollWidth,nav:[...document.querySelectorAll('header a')].map(a=>a.textContent.trim()),h1:document.querySelectorAll('h1').length,images:[...document.images].filter(i=>i.hasAttribute("src")).every(i=>i.naturalWidth>0),current:document.querySelector('header [aria-current=page]')?.getAttribute('href')}));
   if(state.width!==state.scrollWidth||state.h1!==1||!state.images||!state.nav.includes('产品说明')||!state.nav.includes('使用指南'))throw new Error(JSON.stringify(state));
   if(route!=='/' && state.current!==route)throw new Error('aria-current missing: '+route);
   await page.evaluate(()=>scrollTo(0,0));await page.screenshot({path:`output/playwright/velo-product/${route==='/'?'home':route.split('/')[1]}-${width}.png`,fullPage:width===390});checks.push(state);
  }
 }
 await page.goto(base+'/product/');await page.setViewportSize({width:1440,height:960});
 const trigger=page.locator('[data-lightbox]').first();await trigger.click();
 if(!await page.locator('dialog').evaluate(d=>d.open))throw new Error('Image viewer did not open');
 await page.keyboard.press('Escape');if(await page.locator('dialog').evaluate(d=>d.open))throw new Error('Escape did not close');
 if(!await trigger.evaluate(a=>document.activeElement===a))throw new Error('Focus not restored');
 await page.setViewportSize({width:320,height:800});await trigger.click();
 if(!await page.locator('.viewer-scroll').evaluate(e=>e.scrollWidth>e.clientWidth))throw new Error('Mobile original-size detail unavailable');
 await page.getByRole('button',{name:'关闭截图'}).click();
 await page.getByRole('navigation',{name:'主导航',exact:true}).getByRole('link',{name:'使用指南'}).click();await page.waitForURL(base+'/guide/');
 await page.getByRole('button',{name:'切换到深色模式'}).click();
 await page.getByRole('navigation',{name:'主导航',exact:true}).getByRole('link',{name:'产品说明'}).click();await page.waitForURL(base+'/product/');await page.waitForFunction(()=>document.documentElement.dataset.theme==='dark');
 await page.setViewportSize({width:1440,height:960});await page.screenshot({path:'output/playwright/velo-product/product-dark.png'});
 await page.getByRole('navigation',{name:'主导航',exact:true}).getByRole('link',{name:'下载 Velo'}).click();await page.waitForURL(base+'/download/');
 const started=page.waitForEvent('download');await page.locator('[data-download-platform="macos"]').first().click();const download=await started;
 if(download.suggestedFilename()!=='Velo-macos-arm64.dmg'||!await page.locator('#download-next').isVisible())throw new Error('Download follow-up failed');
 await download.saveAs('output/playwright/velo-product/download-check.dmg');
 await page.getByRole('link',{name:'查看首次打开与排障指南'}).click();await page.waitForURL(base+'/guide/#macos-open');
 if(!await page.locator('#macos-open').isVisible())throw new Error('Mac instructions missing');
 await page.getByText('允许之后，没有看到软件窗口？',{exact:true}).click();if(!await page.getByText('允许之后，没有看到软件窗口？',{exact:true}).evaluate(e=>e.parentElement.open))throw new Error('Launch FAQ failed');
 for(const [hash,dest] of [['#download','/download/'],['#faq','/guide/#faq']]){await page.goto(base+'/'+hash);await page.waitForURL(base+dest);}
 if(errors.length)throw new Error(errors.join('\n'));
 return {base,checks,interactions:'image zoom, Escape, focus restoration, mobile image scrolling, real navigation, theme persistence, real DMG download and follow-up, install help, launch FAQ, legacy hashes passed',errors};
}
