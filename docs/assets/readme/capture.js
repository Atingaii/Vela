// Run with playwright-cli run-code --filename docs/assets/readme/capture.js.
// Start npm run preview first; see assets.md for preparing the glyph fixture.
async (page) => {
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript({path:'output/playwright/vela-readme/glyphs.js'});
  await page.addInitScript({path:'docs/assets/readme/demo-bridge.js'});
  await page.emulateMedia({colorScheme:'light',reducedMotion:'reduce'});
  await page.setViewportSize({width:350,height:470});
  await page.goto('http://127.0.0.1:4173/notch.html');
  await page.locator('.cell[data-p="claude"]').waitFor();
  await page.locator('.cell[data-p="claude"]').hover();
  await page.locator('#card.show').waitFor();
  // A neutral desktop backdrop and explicit demo label, outside the product UI.
  await page.addStyleTag({content:'body{background:#e9ece9}'});
  await page.evaluate(() => {
    const label = document.createElement('div');
    label.textContent = '界面预览 · 演示数据';
    label.style.cssText = 'position:fixed;left:20px;bottom:18px;font:11px system-ui;color:#65716c';
    document.body.append(label);
  });
  await page.screenshot({path:'docs/assets/readme/usage-panel.png',animations:'disabled'});
  await page.setViewportSize({width:860,height:600});
  await page.goto('http://127.0.0.1:4173/settings.html');
  await page.locator('#tab-accounts').click();
  await page.locator('#acc-on [data-account]').first().waitFor();
  await page.screenshot({path:'docs/assets/readme/accounts-settings.png',animations:'disabled'});
  if(errors.length)throw new Error(errors.join('\n'));
  return {screenshots:2,source:'Current HTML + synthetic IPC',pageErrors:errors};
}
