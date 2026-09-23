import {test, expect} from '@playwright/test';

async function settingsBridge(page) {
  await page.addInitScript(() => {
    const listeners = {};
    let appearance = {
      accent_color:'system', app_presence:'dock', reset_time:'automatic',
      show_codex_extra:true, show_usage_pace:false, claude_daily_pace:false,
      folds_for_fullscreen:true, weekly_dashed:false, custom_scale:null,
      watch:.5, critical:.7
    };
    let notifications = {
      announce_session_end:true, peek_seconds:5, session_sound:true,
      finished_sound:'Glass', blocked_sound:'Funk', announce_session_limit:true,
      announce_weekly_limit:true, limit_sound:true, limit_sound_name:'Funk',
      announce_reset:true, reset_sound:true, reset_sound_name:'Glass', muted_providers:[]
    };
    let updates = {configured:true, automatic:true, available:null, checking:false, installing:false, message:null};
    let weekly = 'off';
    window.settingsFixture = {
      calls:[], failAppearance:false, failNotifications:false,
      emit(name, payload) { for (const cb of listeners[name] || []) cb({payload}); },
      update(state) { updates = {...updates, ...state}; this.emit('update_state', updates); }
    };
    window.__TAURI__ = {
      core:{invoke:async (cmd, args) => {
        window.settingsFixture.calls.push({cmd, args});
        if (cmd === 'get_appearance') return {...appearance};
        if (cmd === 'set_appearance') {
          if (window.settingsFixture.failAppearance) throw Error('fixture appearance save refused');
          appearance = {...args.prefs}; return {...appearance};
        }
        if (cmd === 'get_notifications') return {...notifications};
        if (cmd === 'set_notifications') {
          if (window.settingsFixture.failNotifications) throw Error('fixture notification save refused');
          notifications = {...args.prefs}; return {...notifications};
        }
        if (cmd === 'get_system_look') return {mica:false, accent:[], symbols:{}};
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
        if (cmd === 'get_monitors') return [];
        if (cmd === 'get_notch_slots' || cmd === 'get_tray_options' || cmd === 'get_disabled_providers' || cmd === 'get_alert_sounds') return [];
        if (cmd === 'get_autostart' || cmd === 'get_hooks_installed') return false;
        return null;
      }},
      event:{listen:async (name, cb) => { (listeners[name] ||= []).push(cb); return () => {}; }},
      app:{getVersion:async () => '1.16.0'},
      window:{getCurrentWindow:() => ({close:async () => {}, startDragging:async () => {}})}
    };
  });
}

test('外观版式遵循原版分组、顺序与控件类型', async ({page}) => {
  await settingsBridge(page);
  await page.setViewportSize({width:860, height:600});
  await page.goto('/settings.html');
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
