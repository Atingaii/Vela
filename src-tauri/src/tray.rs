use crate::i18n::tr;
use crate::traymenu;
use tauri::menu::{CheckMenuItemBuilder, Menu, MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MenuBarEntry {
    pub id: String,
    pub label: String,
    pub percent: String,
    pub countdown: String,
    pub weekly_fraction: Option<u32>,
    pub stale: bool,
    pub detail: String,
}

/// A presentation of existing readings. Selecting a provider for the menu bar never starts a
/// collector, and an expired window cannot keep showing its old percentage while it refreshes.
pub(crate) fn menu_bar_entries(
    rows: &[(String, String, crate::usage::UsageSnapshot)],
    enabled: bool,
    chosen: Option<&[String]>,
    show_weekly: bool,
    now: u64,
    antigravity_model: &str,
    lang: &str,
) -> Vec<MenuBarEntry> {
    if !enabled { return Vec::new(); }
    rows.iter().filter_map(|(id, label, snap)| {
        if snap.status == "absent" || chosen.map_or_else(
            || !is_five_hour_family(id),
            |chosen| !chosen.iter().any(|candidate| candidate == id),
        ) { return None; }
        let window = five_hour_window(id, snap);
        if window.is_none() && !is_five_hour_family(id) { return None; }
        let current = window.is_some_and(|window| window.resets_at.is_none_or(|reset| reset > now));
        let percent = if current {
            window.map_or_else(|| "—".into(), |window| {
                if window.prefers_used_text {
                    if let Some(text) = &window.used_text { return text.clone(); }
                }
                window.fraction().map(whole_percent)
                    .unwrap_or_else(|| traymenu::headline_value(Some(window)))
            })
        } else { "—".into() };
        let countdown = window.and_then(|window| window.resets_at).and_then(|reset| countdown(reset, now, lang))
            .unwrap_or_else(|| "—".into());
        let weekly_fraction = show_weekly.then(|| weekly_window(id, snap, antigravity_model)
            .filter(|window| window.resets_at.is_none_or(|reset| reset > now))
            .and_then(crate::usage::LimitWindow::fraction)
            .map(|fraction| (fraction.clamp(0.0, 1.0) * 1000.0).round() as u32)).flatten();
        let mut detail = if let Some(window) = window {
            let reading = if !current { resetting_label(lang).to_owned() }
                else { traymenu::window_summary(window, lang) };
            let countdown_part = if countdown == "—" { String::new() }
                else { format!(" · {countdown}") };
            format!("{label} — {}: {reading}{countdown_part}", traymenu::label(&window.label, lang))
        } else if let Some(headline) = snap.windows.first() {
            format!("{label} — {}", traymenu::label(&headline.label, lang))
        } else {
            format!("{label} — {}", if snap.note.is_empty() { no_reading_label(lang) } else { &snap.note })
        };
        if let Some(weekly) = weekly_window(id, snap, antigravity_model).filter(|_| weekly_fraction.is_some()) {
            detail.push_str(&format!(" · {}: {}", traymenu::label("Weekly Limit", lang),
                traymenu::used_left(weekly, lang)));
        }
        if snap.status == "stale" && snap.fetched_at > 0 {
            detail.push_str(&format!(" · {}", traymenu::ago(snap.fetched_at, now, lang)));
        }
        Some(MenuBarEntry {
            id: id.clone(), label: label.clone(), percent, countdown,
            weekly_fraction, stale: snap.status == "stale",
            detail,
        })
    }).take(4).collect()
}

fn is_five_hour_family(id: &str) -> bool {
    id == "claude" || id.starts_with("claude-") || id == "codex" || id.starts_with("codex-")
}

fn five_hour_window<'a>(id: &str, snap: &'a crate::usage::UsageSnapshot) -> Option<&'a crate::usage::LimitWindow> {
    let headline_id = if id == "claude" || id.starts_with("claude-") { Some("session") }
        else if id == "codex" || id.starts_with("codex-") { Some("primary") }
        else { crate::providers::CATALOG.iter().find(|p| p.id == id).map(|p| p.headline) };
    let headline = match headline_id {
        Some(key) => snap.windows.iter().find(|w| w.id == key),
        None => snap.windows.first(),
    };
    headline.filter(|w| is_five_hour(w)).or_else(|| {
        snap.windows.iter().find(|w| is_five_hour(w) && w.group.is_none())
    })
}

fn is_five_hour(window: &crate::usage::LimitWindow) -> bool {
    window.duration.is_some_and(|seconds| (seconds - 18_000.0).abs() < 60.0)
}

fn weekly_window<'a>(id: &str, snap: &'a crate::usage::UsageSnapshot, model: &str)
    -> Option<&'a crate::usage::LimitWindow> {
    let by_id = |key: &str| snap.windows.iter().find(|window| window.id == key);
    if id == "claude" || id.starts_with("claude-") {
        return if by_id("daily_pace").is_some() { by_id("session") }
            else { by_id("weekly_all").or_else(|| by_id("seven_day")).or_else(|| by_id("weekly")) };
    }
    if id == "codex" || id.starts_with("codex-") { return by_id("secondary"); }
    if id == "glm" || matches!(id, "commandcode" | "opencode" | "kimi" | "minimax" | "devin" | "ollama-cloud") {
        return by_id("weekly");
    }
    if id == "gemini" || id.starts_with("antigravity-") {
        let matching: Vec<_> = snap.windows.iter().filter(|w| w.id.starts_with(model)).collect();
        let candidates: Vec<_> = if matching.is_empty() { snap.windows.iter().collect() } else { matching };
        return candidates.into_iter().filter(|w| {
            w.duration == Some(604_800.0) || w.id.to_ascii_lowercase().ends_with("-weekly")
                || w.label.to_ascii_lowercase().contains("weekly")
        }).max_by(|a, b| a.used.total_cmp(&b.used).then_with(|| b.id.cmp(&a.id)));
    }
    None
}

fn whole_percent(fraction: f64) -> String {
    let value = (fraction * 100.0).max(0.0);
    if value > 0.0 && value < 1.0 { "<1%".into() }
    else if value > 99.0 && value < 100.0 { "99%".into() }
    else { format!("{}%", value.round() as u64) }
}

fn countdown(reset: u64, now: u64, lang: &str) -> Option<String> {
    let remaining = reset.checked_sub(now)?;
    if remaining == 0 { return None; }
    let minutes = remaining / 60_000;
    Some(if minutes == 0 { match lang {
        "zh" => "<1分钟".into(), "zh-Hant" => "<1分鐘".into(), "ja" => "<1分".into(),
        "ko" => "1분 미만".into(), "ru" => "<1 мин".into(), "uk" => "<1 хв".into(),
        "pt-BR" | "fr" | "de" => "<1 min".into(), "uz" => "<1 daq".into(), _ => "<1m".into(),
    }} else if minutes < 60 { match lang {
        "zh" => format!("{minutes}分钟"), "zh-Hant" => format!("{minutes}分鐘"),
        "ja" => format!("{minutes}分"), "ko" => format!("{minutes}분"),
        "ru" => format!("{minutes} мин"), "uk" => format!("{minutes} хв"),
        "pt-BR" | "fr" | "de" => format!("{minutes} min"), "uz" => format!("{minutes} daqiqa"), _ => format!("{minutes}m"),
    }} else {
        let h = minutes / 60; let m = minutes % 60;
        match lang {
            "zh" => format!("{h}小时{m:02}分"), "zh-Hant" => format!("{h}小時{m:02}分"),
            "ja" => format!("{h}時間{m:02}分"), "ko" => format!("{h}시간 {m:02}분"),
            "ru" => format!("{h} ч {m:02} мин"), "uk" => format!("{h} год {m:02} хв"),
            "fr" => format!("{h}h {m:02}m"), "de" => format!("{h} h {m:02} min"),
            "uz" => format!("{h} soat {m:02} daqiqa"),
            "pt-BR" => format!("{h}h {m:02}m"), _ => format!("{h}h {m:02}m"),
        }
    })
}

#[cfg(target_os = "macos")]
pub(crate) fn countdown_room(lang: &str) -> String {
    countdown(5 * 3_600_000 - 30_000, 0, lang).unwrap_or_default()
}

fn summary_rows(app: &AppHandle) -> Vec<(String, String, crate::usage::UsageSnapshot)> {
    crate::get_tray_options(app.clone()).into_iter()
        .filter(|row| crate::providers::enabled(app, &row.id))
        .map(|row| {
            let snap = crate::snapshot_of(app, &row.id);
            (row.id, row.label, snap)
        }).collect()
}

#[derive(serde::Serialize)]
pub struct MenuBarChoice {
    id: String,
    name: String,
}

/// The same connected five-hour providers that can appear on the status item. This list is
/// presentation-only: selecting one does not connect or disconnect its account.
#[tauri::command]
pub fn get_menu_bar_choices(app: AppHandle) -> Vec<MenuBarChoice> {
    summary_rows(&app).into_iter().filter_map(|(id, name, snap)| {
        if snap.status != "absent" && (is_five_hour_family(&id) || five_hour_window(&id, &snap).is_some()) {
            Some(MenuBarChoice { id, name })
        } else { None }
    }).collect()
}

fn refresh_menu_bar_face(app: &AppHandle, tray: &tauri::tray::TrayIcon) {
    #[cfg(target_os = "macos")]
    {
        let cfg = app.state::<crate::AppState>().cfg.lock().unwrap().clone();
        let prefs = cfg.appearance;
        let lang = language(app);
        let rows = summary_rows(app);
        let entries = menu_bar_entries(&rows, prefs.shows_limits_in_menu_bar,
            prefs.menu_bar_providers.as_deref(), prefs.shows_weekly_limit_in_menu_bar, crate::now_ms(),
            &cfg.antigravity_model, &lang);
        apply_menu_bar_face(app, tray, entries, &lang);
    }
    #[cfg(not(target_os = "macos"))]
    { let _ = (app, tray); }
}

#[cfg(target_os = "macos")]
fn apply_menu_bar_face(app: &AppHandle, tray: &tauri::tray::TrayIcon, entries: Vec<MenuBarEntry>, lang: &str) {
    let mut shown = SHOWN_FACE.lock().unwrap();
    if shown.as_ref() == Some(&entries) { return; }
    let result = if entries.is_empty() {
        let _ = tray.set_title::<&str>(None);
        tray.set_icon_with_as_template(crate::trayicon::app_mark(), true)
    } else if let Some(image) = crate::status_item_artwork::render(app, &entries, lang) {
        let _ = tray.set_title::<&str>(None);
        tray.set_icon_with_as_template(Some(image), true)
    } else {
        // Keep the reading accessible if AppKit could not rasterize a template image.
        let compact = entries.len() > 2;
        let title = entries.iter().map(|entry| {
            if compact { format!("{} {}", entry.label, entry.percent) }
            else { format!("{} {} · {}", entry.label, entry.percent, entry.countdown) }
        }).collect::<Vec<_>>().join("  |  ");
        let _ = tray.set_icon_with_as_template(None, true);
        tray.set_title(Some(title))
    };
    if result.is_ok() {
        let _ = tray.set_tooltip(Some(&summary_tooltip(&entries)));
        *shown = Some(entries);
    }
}

#[cfg(target_os = "macos")]
fn summary_tooltip(entries: &[MenuBarEntry]) -> String {
    if entries.is_empty() { "Velo".into() }
    else { entries.iter().map(|entry| entry.detail.as_str()).collect::<Vec<_>>().join("\n") }
}

/// The countdown changes between provider fetches. Compute its small, pure input off the AppKit
/// thread; only drawing and swapping the status image are posted to the UI thread.
pub fn refresh_summary(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let cfg = app.state::<crate::AppState>().cfg.lock().unwrap().clone();
        let prefs = cfg.appearance;
        if prefs.app_presence != "menuBar" || !prefs.shows_limits_in_menu_bar { return; }
        let lang = language(app);
        let rows = summary_rows(app);
        let entries = menu_bar_entries(&rows, true, prefs.menu_bar_providers.as_deref(),
            prefs.shows_weekly_limit_in_menu_bar, crate::now_ms(), &cfg.antigravity_model, &lang);
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            if let Some(tray) = handle.tray_by_id("main") { apply_menu_bar_face(&handle, &tray, entries, &lang); }
        });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = app;
}

static SHOWN_FACE: std::sync::Mutex<Option<Vec<MenuBarEntry>>> = std::sync::Mutex::new(None);

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app)?;
    let mut builder = TrayIconBuilder::with_id("main");
    // Windows does not tint tray icons and the monochrome outline vanishes on a dark taskbar, so
    // the app's own mark is the icon. trayicon::app_mark explains why at length.
    if let Some(icon) = crate::trayicon::app_mark() {
        builder = builder.icon(icon);
    }
    builder
        .tooltip(concat!("Velo v", env!("CARGO_PKG_VERSION")))
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, ev| handle(app, ev.id().as_ref()))
        .build(app)?;
    Ok(())
}

/// The readings themselves, as the Mac's menu bar shows them: a line per provider with its headline
/// figure, and under it one greyed line per limit window. The macOS menu is rebuilt as it opens;
/// Tauri has no such hook, so `refresh_menu` is called whenever a reading changes and once a minute
/// besides, which keeps "Resets in 12 min" honest.
/// Every line the menu would show, in order, with the id each carries. Kept apart from building the
/// menu so a refresh can tell whether anything visible changed before it swaps the menu out.
fn menu_lines(app: &AppHandle, lang: &str) -> Vec<(String, String, bool)> {
    let now = crate::now_ms();
    let mut lines = Vec::new();
    for provider in crate::get_tray_options(app.clone()) {
        let id = provider.id.as_str();
        if !crate::providers::enabled(app, id) {
            continue;
        }
        let snap = crate::snapshot_of(app, id);
        if snap.status == "absent" {
            continue;
        }
        let head = traymenu::header_value(
            &provider.label,
            &provider.text,
            traymenu::stale_since(&snap, now),
            now,
            lang,
        );
        // Clicking a provider re-reads that one, as on the Mac.
        lines.push((format!("refresh:{id}"), head, true));
        for (n, line) in traymenu::provider_lines(&snap, now, lang)
            .iter()
            .enumerate()
        {
            // Windows does not indent submenu-less items, so the indent is in the text.
            lines.push((format!("line:{id}:{n}"), format!("    {line}"), false));
        }
    }
    lines
}

pub fn build_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let lang = language(app);
    build_menu_from(app, &lang, &menu_lines(app, &lang))
}

fn build_menu_from(
    app: &AppHandle,
    lang: &str,
    lines: &[(String, String, bool)],
) -> tauri::Result<Menu<Wry>> {
    let lang = lang.to_string();
    let mut items: Vec<tauri::menu::MenuItem<Wry>> = Vec::new();
    for (id, text, enabled) in lines {
        items.push(
            MenuItemBuilder::with_id(id.clone(), text.clone())
                .enabled(*enabled)
                .build(app)?,
        );
    }
    if items.is_empty() {
        items.push(
            MenuItemBuilder::with_id("waiting", tr(&lang, "waiting"))
                .enabled(false)
                .build(app)?,
        );
    }
    let refresh = MenuItemBuilder::with_id("refresh", tr(&lang, "refresh_all"))
        .accelerator("CmdOrCtrl+R")
        .build(app)?;
    #[cfg(target_os = "macos")]
    let show_limits = CheckMenuItemBuilder::with_id("show_menu_bar_limits", menu_bar_toggle_label(&lang))
        .checked(app.state::<crate::AppState>().cfg.lock().unwrap().appearance.shows_limits_in_menu_bar)
        .build(app)?;
    let settings = MenuItemBuilder::with_id("settings", tr(&lang, "settings"))
        .accelerator("CmdOrCtrl+,")
        .build(app)?;
    let quit = MenuItemBuilder::with_id("quit", tr(&lang, "quit_app"))
        .accelerator("CmdOrCtrl+Q")
        .build(app)?;
    let mut menu = MenuBuilder::new(app);
    for item in &items {
        menu = menu.item(item);
    }
    menu = menu.separator();
    #[cfg(target_os = "macos")]
    { menu = menu.item(&show_limits).separator(); }
    menu.item(&refresh)
        .item(&settings)
        .separator()
        .item(&quit)
        .build()
}

/// The language the menu speaks, already resolved: `traymenu` picks its wording by code and has no
/// "auto" of its own.
pub(crate) fn language(app: &AppHandle) -> String {
    let st = app.state::<crate::AppState>();
    let raw = st.cfg.lock().unwrap().lang.clone();
    crate::resolved_lang(&raw)
}

/// The hover text: the same figures the menu opens with, for when the menu is not open.
fn tooltip(app: &AppHandle) -> String {
    #[cfg(target_os = "macos")]
    {
        let cfg = app.state::<crate::AppState>().cfg.lock().unwrap().clone();
        if cfg.appearance.app_presence == "menuBar" && cfg.appearance.shows_limits_in_menu_bar {
            let entries = menu_bar_entries(&summary_rows(app), true,
                cfg.appearance.menu_bar_providers.as_deref(),
                cfg.appearance.shows_weekly_limit_in_menu_bar, crate::now_ms(),
                &cfg.antigravity_model, &language(app));
            return summary_tooltip(&entries);
        }
        return "Velo".into();
    }
    #[cfg(not(target_os = "macos"))]
    {
    let mut parts: Vec<String> = Vec::new();
    for provider in crate::get_tray_options(app.clone()) {
        let id = provider.id.as_str();
        if !crate::providers::enabled(app, id) {
            continue;
        }
        if crate::snapshot_of(app, id).status == "absent" {
            continue;
        }
        let value = crate::ring_fraction(app, id)
            .map(|f| format!("{}%", traymenu::pct(f)))
            .unwrap_or_else(|| "—".into());
        parts.push(format!("{} {value}", provider.label));
    }
    if parts.is_empty() {
        concat!("Velo v", env!("CARGO_PKG_VERSION")).to_string()
    } else {
        format!("Velo — {}", parts.join(" · "))
    }
    }
}

fn menu_bar_toggle_label(lang: &str) -> &'static str {
    match lang {
        "zh" => "在菜单栏显示额度信息", "zh-Hant" => "在選單列顯示額度資訊",
        "ja" => "メニューバーに上限の情報を表示", "ko" => "메뉴 막대에 한도 정보 표시",
        "ru" => "Показывать лимиты в строке меню", "uk" => "Показувати ліміти в рядку меню",
        "pt-BR" => "Exibir limites na barra de menus",
        "fr" => "Afficher les limites dans la barre des menus",
        "de" => "Limits in der Menüleiste anzeigen",
        "uz" => "Menyu panelida limit maʼlumotini koʻrsatish",
        _ => "Show limit information in menu bar",
    }
}

fn resetting_label(lang: &str) -> &'static str {
    match lang {
        "zh" | "zh-Hant" => "正在重置…", "ja" => "リセット中…", "ko" => "재설정 중…",
        "ru" => "Сброс…", "uk" => "Скидання…", "pt-BR" => "Renovando…",
        "fr" => "Réinitialisation…", "de" => "Wird zurückgesetzt…", "uz" => "Yangilanmoqda…",
        _ => "Resetting…",
    }
}

fn no_reading_label(lang: &str) -> &'static str {
    match lang {
        "zh" => "暂无读数", "zh-Hant" => "暫無讀數", "ja" => "読み取りなし",
        "ko" => "읽은 값 없음", "ru" => "Нет данных", "uk" => "Немає даних",
        "pt-BR" => "Sem leitura", "fr" => "Aucun relevé", "de" => "Kein Messwert",
        "uz" => "Maʼlumot yoʻq", _ => "No reading",
    }
}

/// Rebuilds the tray menu, ALWAYS on the main thread.
///
/// A menu is a Windows UI object. Building one or swapping it in from another thread leaves the
/// tray holding a menu that never opens again — and since changing the language is what triggers a
/// rebuild, the user is then locked out of the only place they could change it back. The tray's own
/// click handlers already run on the main thread, but the readings poller and the settings window
/// do not, so the hop is done here once rather than being remembered at every call site.
/// What the menu last showed, so an unchanged refresh leaves it alone.
static SHOWN: std::sync::Mutex<Option<(String, Vec<(String, String, bool)>, bool)>> =
    std::sync::Mutex::new(None);

/// Swaps the menu only when a line of it would read differently. `set_menu` replaces the menu the
/// user may have open this moment — the refresh runs on the main thread, which the open popup's
/// message loop still serves — so the minute tick used to close it under the pointer even when
/// "Resets in 12 min" still said 12 min.
pub fn refresh_menu(app: &AppHandle) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Some(tray) = handle.tray_by_id("main") {
            refresh_menu_bar_face(&handle, &tray);
            let lang = language(&handle);
            let lines = menu_lines(&handle, &lang);
            let menu_bar_limits = handle.state::<crate::AppState>().cfg.lock().unwrap()
                .appearance.shows_limits_in_menu_bar;
            let key = (lang.clone(), lines.clone(), menu_bar_limits);
            if SHOWN.lock().unwrap().as_ref() == Some(&key) {
                // A tooltip can change without a line changing, and setting it closes nothing.
                let _ = tray.set_tooltip(Some(&tooltip(&handle)));
                return;
            }
            match build_menu_from(&handle, &lang, &lines) {
                Ok(menu) => {
                    let _ = tray.set_menu(Some(menu));
                    let _ = tray.set_tooltip(Some(&tooltip(&handle)));
                    *SHOWN.lock().unwrap() = Some(key);
                }
                Err(e) => crate::applog(&format!("tray menu: {e}")),
            }
        }
    });
}

/// Provider rows carry `refresh:<id>`; everything else the menu offers is one of the four fixed
/// items. Settings, language, hooks and the rest arrive as commands from the settings window.
fn handle(app: &AppHandle, id: &str) {
    if let Some(provider) = id.strip_prefix("refresh:") {
        crate::refresh_provider(app, provider);
        return;
    }
    match id {
        "show_menu_bar_limits" => {
            let st = app.state::<crate::AppState>();
            let mut cfg = st.cfg.lock().unwrap();
            let mut next = cfg.clone();
            next.appearance.shows_limits_in_menu_bar = !next.appearance.shows_limits_in_menu_bar;
            if let Err(error) = crate::config::save_checked(&next) {
                crate::applog(&format!("menu bar preference: {error}"));
                *SHOWN.lock().unwrap() = None;
                drop(cfg);
                refresh_menu(app);
                return;
            }
            let appearance = next.appearance.clone();
            *cfg = next;
            drop(cfg);
            let _ = app.emit("appearance", appearance);
            refresh_menu(app);
        }
        "refresh" => crate::refresh_all(app),
        "settings" => crate::settings_window::open(app),
        "quit" => app.exit(0),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::usage::{LimitWindow, UsageSnapshot};

    fn row(id: &str, reset: Option<u64>, used: f64) -> (String, String, UsageSnapshot) {
        (id.into(), id.into(), UsageSnapshot {
            status: "ok".into(),
            windows: vec![LimitWindow {
                id: if id.starts_with("codex") { "primary" } else { "session" }.into(),
                used, resets_at: reset, duration: Some(18_000.0), ..Default::default()
            }],
            ..Default::default()
        })
    }

    #[test]
    fn menu_bar_selection_is_presentation_only_and_expired_readings_do_not_linger() {
        let now = 1_000_000;
        let rows = vec![row("claude", Some(now + 7_200_000), 0.725),
            row("codex-work", Some(now - 1), 0.5),
            ("cursor".into(), "Cursor".into(), UsageSnapshot {status:"ok".into(),
                windows:vec![LimitWindow {id:"included".into(), used:0.1,
                    resets_at:Some(now + 60_000), ..Default::default()}], ..Default::default()})];
        let defaults = menu_bar_entries(&rows, true, None, false, now, "gemini", "en");
        assert_eq!(defaults.iter().map(|entry| entry.id.as_str()).collect::<Vec<_>>(),
            vec!["claude", "codex-work"]);
        assert_eq!(defaults[0].percent, "73%");
        assert_eq!(defaults[0].countdown, "2h 00m");
        assert_eq!(defaults[1].percent, "—");
        assert_eq!(defaults[1].countdown, "—");
        assert!(menu_bar_entries(&rows, true, Some(&[]), false, now, "gemini", "en").is_empty());
        assert_eq!(menu_bar_entries(&rows, true, Some(&["cursor".into()]), false, now, "gemini", "en").len(), 0);
        assert!(menu_bar_entries(&rows, false, None, false, now, "gemini", "en").is_empty());
    }

    #[test]
    fn missing_five_hour_family_is_a_dash_and_fraction_edges_are_honest() {
        let now = 1_000_000;
        let rows = vec![row("claude", None, 0.003),
            ("codex".into(), "Codex".into(), UsageSnapshot { status: "needsAuth".into(), ..Default::default() }),
            row("claude-work", None, 0.997)];
        let entries = menu_bar_entries(&rows, true, None, false, now, "gemini", "en");
        assert_eq!(entries.iter().map(|entry| entry.percent.as_str()).collect::<Vec<_>>(),
            vec!["<1%", "—", "99%"]);
        assert!(entries.iter().all(|entry| entry.countdown == "—"));
    }

    #[test]
    fn weekly_uses_provider_declared_window_and_never_grouped_spark_for_session() {
        let now = 1_000_000;
        let codex = ("codex".into(), "Codex".into(), UsageSnapshot {
            status: "ok".into(),
            windows: vec![LimitWindow {id:"primary".into(), duration:Some(18_000.0), used:0.2,
                ..Default::default()}, LimitWindow {id:"secondary".into(), duration:Some(604_800.0),
                used:0.7, ..Default::default()}], ..Default::default()
        });
        let grouped = ("opencode".into(), "OpenCode".into(), UsageSnapshot {
            status: "ok".into(), windows: vec![LimitWindow {id:"spark".into(), duration:Some(18_000.0),
                group:Some("Spark".into()), used:0.9, ..Default::default()}], ..Default::default()
        });
        let entries = menu_bar_entries(&[codex, grouped], true,
            Some(&["codex".into(), "opencode".into()]), true, now, "gemini", "zh");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].weekly_fraction, Some(700));
        assert!(five_hour_window("opencode", &UsageSnapshot {windows:vec![LimitWindow {
            id:"spark".into(), duration:Some(18_000.0), group:Some("Spark".into()),
            ..Default::default()}], ..Default::default()}).is_none());
    }

    #[test]
    fn duration_tolerance_is_strict_and_countdown_is_localized() {
        let mut snap = UsageSnapshot {windows:vec![LimitWindow {id:"session".into(),
            duration:Some(18_060.0), ..Default::default()}], ..Default::default()};
        assert!(five_hour_window("claude", &snap).is_none());
        snap.windows[0].duration = Some(18_059.0);
        assert!(five_hour_window("claude", &snap).is_some());
        assert_eq!(countdown(7_200_000, 0, "zh"), Some("2小时00分".into()));
        assert_eq!(countdown(59_000, 0, "ja"), Some("<1分".into()));
        assert_eq!(countdown(59_000, 0, "fr"), Some("<1 min".into()));
        assert_eq!(countdown(65 * 60_000, 0, "de"), Some("1 h 05 min".into()));
        assert_eq!(countdown(65 * 60_000, 0, "uz"), Some("1 soat 05 daqiqa".into()));
        assert_eq!(menu_bar_toggle_label("fr"), "Afficher les limites dans la barre des menus");
        assert_eq!(resetting_label("de"), "Wird zurückgesetzt…");
        assert_eq!(no_reading_label("uz"), "Maʼlumot yoʻq");
    }

    #[test]
    fn compact_summary_keeps_countdown_weekly_and_stale_age_in_detail() {
        let now = 2_000_000;
        let mut first = row("codex", Some(now + 7_200_000), 0.5);
        first.2.status = "stale".into();
        first.2.fetched_at = now - 120_000;
        first.2.windows.push(LimitWindow {id:"secondary".into(), label:"Weekly Limit".into(),
            duration:Some(604_800.0), used:0.7, ..Default::default()});
        let entries = menu_bar_entries(&[first, row("claude", None, 0.1),
            row("claude-work", None, 0.2)], true, None, true, now, "gemini", "en");
        assert_eq!(entries.len(), 3);
        assert!(entries[0].detail.contains("2h 00m"));
        assert!(entries[0].detail.contains("Weekly Limit"));
        assert!(entries[0].detail.contains("2m ago"));
    }
}
