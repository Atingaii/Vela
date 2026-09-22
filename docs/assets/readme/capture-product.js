// Current product HTML, unchanged styles, synthetic IPC; never a native-account claim.
// See assets.md. Run via playwright-cli run-code --filename.
async (page) => {
 const context=await page.context().browser().newContext({viewport:{width:860,height:600},deviceScaleFactor:2,colorScheme:'light',reducedMotion:'reduce'});
 const view=await context.newPage(),errors=[];view.on('pageerror',e=>errors.push(e.message));
 await view.addInitScript({path:'output/playwright/velo-product/glyphs.js'});
 await view.addInitScript({path:'docs/assets/readme/demo-bridge.js'});
 await view.setViewportSize({width:350,height:470});
 await view.goto('http://127.0.0.1:4173/notch.html');
 await view.locator('.cell[data-p="claude"]').hover();
 await view.locator('#card.show').waitFor();
 await view.screenshot({path:'website/assets/product-usage.png',omitBackground:true,animations:'disabled'});
 await view.setViewportSize({width:860,height:600});
 await view.goto('http://127.0.0.1:4173/settings.html');
 const records=[];
 for(const tab of ['accounts','appearance','notifications']){
  await view.locator('#tab-'+tab).click();
  await view.locator('#pane-'+tab).waitFor({state:'visible'});
  await view.evaluate(()=>document.fonts.ready);
  await view.screenshot({path:`website/assets/product-${tab}.png`,animations:'disabled'});
  records.push({tab,visible:await view.locator('#pane-'+tab).innerText()});
  if(tab==='appearance'){
   await view.locator('#seg-edge').scrollIntoViewIfNeeded();
   await view.screenshot({path:'website/assets/product-position.png',animations:'disabled'});
  }
 }
 if(errors.length)throw new Error(errors.join('\n'));
 await context.close();
 return {source:'src-tauri/ui actual HTML, synthetic IPC, unchanged product styles',scale:2,errors,records};
}
