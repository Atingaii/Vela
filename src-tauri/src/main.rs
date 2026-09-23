#![cfg_attr(all(not(debug_assertions), windows), windows_subsystem = "windows")]

mod activity;
mod account_destination;
mod agy_cli;
mod antigravity;
mod appearance;
mod autostart;
mod chime;
mod claude_auth;
mod claude_session_monitor;
mod cli_sync;
mod codex;
mod config;
mod cursor;
mod custom_endpoint;
mod diag;
mod doctor;
mod dropzones;
mod edge_plugins;
mod focus;
mod front_window;
mod glm;
mod glyphs;
mod gemini_api_activity;
mod grok;
mod grok_activity;
mod hooks_install;
mod i18n;
mod ledger;
mod kimi_activity;
mod local_runtime;
mod local_metrics;
mod lmstudio_log;
mod lmstudio_link;
mod lmstudio_metrics;
mod ollama_relay;
mod ollama_stream;
mod native_notch;
#[cfg(target_os = "macos")]
mod native_lifecycle;
mod notch_layout;
mod edge_transition;
mod notch_window;
mod notchmenu;
mod notifications;
mod pace;
mod phone_link;
mod platform;
mod providers;
mod refresh;
mod secrets;
mod server;
mod settings_window;
mod smoke;
mod state;
mod status_item_artwork;
mod tray;
mod trayicon;
mod traymenu;
mod terminal_tab_focus;
mod updater;
mod updater_stage;
mod usage;
mod usage_alerts;
mod watcher;
#[cfg(windows)]
mod windows_lifecycle;
mod web_sites;
mod web_usage_detail;
mod web_session;
mod workbench;
mod whats_new;

use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager};

/// Logical size of the notch window: the 70 pt pill column on the right plus room for the hover card
/// and its tail on the left. `fitZoom` in ui/notch.html divides by the same width.
pub const NOTCH_W: f64 = 360.0;
/// Hand-bumped build tag, written to run.log at startup so a log can always be matched to the exe that wrote it.
pub const BUILD: &str = env!("CARGO_PKG_VERSION");
/// The notch window's long side: the upright window's height, and both sides of the flat one.
///
/// Five cells make a 447 px pill; its fillets add 38.7 px at each end and the settings orb reaches
/// 28.5 px past the far one, so 520 cut both fillets and hid the orb. The card wants the same room:
/// 300 clipped it once it held three window blocks plus the session list, and 460 clipped
/// Antigravity's two model groups once the reading was stale and an agent was working.
pub const NOTCH_LONG: f64 = 650.0;

pub struct AppState {
    pub store: Mutex<state::Store>,
    pub cfg: Mutex<config::Config>,
    pub usage: Mutex<usage::UsageSnapshot>,
    /// Codex snapshot (same UsageSnapshot shape; status may also be none/absent)
    pub codex: Mutex<usage::UsageSnapshot>,
    pub cursor: Mutex<usage::UsageSnapshot>,
    /// Grok Build credits, read from the Grok CLI's own session
    pub grok: Mutex<usage::UsageSnapshot>,
    pub antigravity: Mutex<usage::UsageSnapshot>,
    /// GLM Coding Plan snapshot, read from the existing Z.AI tool credentials.
    pub glm: Mutex<usage::UsageSnapshot>,
    /// Provider glyph cache, collected at launch and again on a tray refresh
    pub glyphs: Mutex<std::collections::HashMap<String, glyphs::Glyph>>,
    /// Working state of the non-Claude providers (Cursor reports it; Codex and Antigravity are inferred from recent writes)
    pub activity: Mutex<Vec<activity::Activity>>,
}

fn resolved_lang(raw: &str) -> String {
    if raw == "auto" {
        i18n::resolve_auto().to_string()
    } else if raw == "zh-Hans" {
        // Persist the Swift-facing locale name, but existing Rust tray and What’s New
        // translations use `zh` as their Simplified Chinese key.
        "zh".into()
    } else {
        raw.to_string()
    }
}

/// The notch size chosen in Settings: Small, Medium or Large, as a multiple of the designed size.
pub fn ui_scale(app: &AppHandle) -> f64 {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.appearance.effective_scale(c.scale)
}

pub fn broadcast(app: &AppHandle) {
    let st = app.state::<AppState>();
    let snap = {
        let store = st.store.lock().unwrap();
        let cfg = st.cfg.lock().unwrap();
        store.snapshot_filtered(
            &cfg.lang,
            &resolved_lang(&cfg.lang),
            i18n::clock_24h(),
            false,
            &cfg.providers.disabled,
        )
    };
    notifications::observe(app);
    let _ = app.emit("state", &snap);
}

/// A monitor reduced to the numbers placement needs, so the borrowed `Monitor` does not have to be
/// held across the config lock.
#[derive(Clone, Debug)]
pub struct Screen {
    pub name: Option<String>,
    /// macOS ColorSync display UUID, independent of resolution and arrangement.
    pub stable_id: Option<String>,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub scale: f64,
    /// The work area: the monitor less the taskbar and anything else docked to its edges.
    pub work: (i32, i32, i32, i32),
}

impl Screen {
    fn of(m: &tauri::window::Monitor) -> Self {
        let wa = m.work_area();
        Self {
            name: m.name().cloned(),
            stable_id: None,
            x: m.position().x,
            y: m.position().y,
            w: m.size().width as i32,
            h: m.size().height as i32,
            scale: m.scale_factor(),
            work: (
                wa.position.x,
                wa.position.y,
                wa.size.width as i32,
                wa.size.height as i32,
            ),
        }
    }
    /// The Swift notch attaches to physical screen edges. Work-area insets only keep
    /// the expanded card away from the Dock/taskbar; they never move the edge itself.
    fn area(&self) -> (i32, i32, i32, i32) {
        (self.x, self.y, self.w, self.h)
    }
}

/// Every attached monitor, primary first so a stale name always falls back to something sensible.
pub fn screens(app: &AppHandle) -> Vec<Screen> {
    let Some(w) = app.get_webview_window("notch") else {
        return Vec::new();
    };
    let primary = w.primary_monitor().ok().flatten().map(|m| Screen::of(&m));
    let mut out: Vec<Screen> = Vec::new();
    if let Some(p) = primary.clone() {
        out.push(p);
    }
    if let Ok(all) = w.available_monitors() {
        for m in all {
            let s = Screen::of(&m);
            if !out
                .iter()
                .any(|o| o.name == s.name && o.x == s.x && o.y == s.y)
            {
                out.push(s);
            }
        }
    }
    for screen in &mut out {
        screen.stable_id = native_notch::cached_display_id(screen);
    }
    out
}

/// Pin to an attached display, otherwise follow the frontmost window with a primary fallback.
fn target_screen(app: &AppHandle) -> Option<Screen> {
    let want = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        c.notch_monitor.clone()
    };
    let list = screens(app);
    if let Some(name) = want {
        if let Some(s) = list.iter().find(|s| {
            screen_id_matches(s, &name)
        }) {
            return Some(s.clone());
        }
    }
    if let Some(window) = front_window::selected() {
        if let Some(screen) = list
            .iter()
            .filter(|s| window.intersection(front_window::screen_rect(s)) > 0.0)
            .max_by(|a, b| {
                window
                    .intersection(front_window::screen_rect(a))
                    .total_cmp(&window.intersection(front_window::screen_rect(b)))
            })
        {
            return Some(screen.clone());
        }
    }
    list.into_iter().next()
}

fn screen_id_matches(screen: &Screen, id: &str) -> bool {
    screen.stable_id.as_deref() == Some(id) || screen.name.as_deref() == Some(id)
}

/// The window's top-left corner for an edge, a position ratio along it and a measured window size.
/// `ratio` is the *centre* of the notch along the edge, so 0.5 is the middle whatever the size.
/// The work area, not the monitor: a notch on the edge the taskbar is docked to would otherwise be
/// covered by it. The Mac places against `frame` rather than `visibleFrame` on purpose, but what it
/// overlaps there is the menu bar, which macOS lets a notch cover; the taskbar wins the z-order
/// among topmost windows and is a click target of its own, so it is room lost.
fn edge_origin(s: &Screen, edge: &str, ww: i32, wh: i32, ratio: f64) -> (i32, i32) {
    let (ax, ay, aw, ah) = s.area();
    let along = |span: i32, len: i32| -> i32 {
        let v = (span as f64 * ratio - len as f64 / 2.0).round() as i32;
        v.clamp(0, (span - len).max(0))
    };
    match edge {
        "left" => (ax, ay + along(ah, wh)),
        "top" => (ax + along(aw, ww), ay),
        "bottom" => (ax + along(aw, ww), ay + ah - wh),
        _ => (ax + aw - ww, ay + along(ah, wh)),
    }
}

/// The landing whose pill is being kept out of sight, or 0. Numbered so a fallback timer from one
/// landing can never reveal the next one early.
/// Longest a landing stays out of sight if the page never reports a settled layout.
const LANDING_FALLBACK_MS: u64 = 700;

/// Places the notch on a screen at another scale without the change of scale showing.
///
/// Arriving there, Windows resizes the window by the ratio of the two scales before `place_notch`
/// puts it right, and the page then re-zooms itself for the new pixel ratio a debounce later, which
/// can bring one more zoom correction from `report_dpr`. All of that played out on screen as the
/// notch jumping sizes as it landed. Hiding the window did not help: a hidden WebView2 stops painting
/// and throttles its timers, so the page only caught up once it was shown again, in plain view.
///
/// So the window stays up and the page empties itself instead — the window is transparent, so an
/// empty page is an invisible notch — while the WebView keeps doing its layout. It is revealed when
/// the page reports a layout that has stopped changing (`report_dpr` with `settled`), not after a
/// guessed delay. At the same scale nothing is resized on arrival, so there is nothing to hide.
fn land_on_another_screen(app: &AppHandle, from_scale: f64, to_scale: f64) {
    if (from_scale - to_scale).abs() < 0.01 {
        return place_notch(app);
    }
    let runtime = native_notch::runtime("notch");
    let gen = {
        let mut rt = runtime.lock().unwrap();
        rt.landing_seq = rt.landing_seq.wrapping_add(1).max(1);
        rt.landing = rt.landing_seq;
        rt.landing
    };
    let _ = app.emit_to("notch", "notch_landing", ());
    // Moved before the page has painted itself empty, the jump would show after all
    for _ in 0..40 {
        if runtime.lock().unwrap().landing_hidden == gen {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    place_notch(app);
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(LANDING_FALLBACK_MS));
        let mut rt = runtime.lock().unwrap();
        let reveal = rt.landing == gen;
        if reveal {
            rt.landing = 0;
        }
        drop(rt);
        if reveal {
            applog("notch landing: no settled layout reported, shown anyway");
            let _ = app.emit_to("notch", "notch_reveal", ());
        }
    });
}

/// The page has painted itself empty for the landing in progress.
#[tauri::command]
fn notch_hidden(window: tauri::WebviewWindow) {
    let runtime = native_notch::runtime(window.label());
    let mut rt = runtime.lock().unwrap();
    rt.landing_hidden = rt.landing;
}

/// `edge_origin` run backwards along one axis: where a window at `pos`, `len` long, has its centre,
/// as a fraction of the span from `start`. What a slide along the edge saves, so it lands exactly
/// where it was let go.
fn along_at(pos: i32, len: i32, start: i32, span: i32) -> f64 {
    (((pos - start) as f64 + len as f64 / 2.0) / span.max(1) as f64).clamp(0.0, 1.0)
}

/// NotchViewModel.leadingExtent/trailingExtent. The shape excludes the settings
/// and move handles; their full hot circles must still stay on the display.
/// AppKit rounds these extents up in screen points before the panel is placed.
fn handle_extents(
    edge: &str,
    size_scale: f64,
    monitor_scale: f64,
    show_move: bool,
    hardware: Option<native_notch::HardwareNotch>,
) -> (f64, f64) {
    const K: f64 = 44.0 / 117.0;
    let beyond_shape = if edge == "top" {
        hardware.map_or(0.0, |notch| {
            let corner = (78.8 * K).min(notch.height / 2.0);
            let offset = (corner + 27.0 * K + 62.0 * K) / 2.0_f64.sqrt();
            offset - 28.0 * K - corner
        })
    } else {
        0.0
    };
    let full = ((beyond_shape + 152.0 * K / 2.0).max(0.0) * size_scale).ceil()
        * monitor_scale;
    (if show_move { full } else { 0.0 }, full)
}

/// Physical top/left panel origin. Swift NotchGeometry.panelFrame clamps by the
/// visible shape plus handle extents, allowing transparent card slack offscreen.
/// Its small-screen fallback chooses the leading limit when the limits cross.
fn visible_along_origin(
    wanted: f64,
    start: i32,
    span: i32,
    panel_len: i32,
    shape: Option<f64>,
    leading: f64,
    trailing: f64,
    vertical: bool,
) -> i32 {
    let slack = (panel_len as f64 - shape.unwrap_or(panel_len as f64)) / 2.0;
    let lo = start as f64 - slack + leading;
    let hi = (start + span - panel_len) as f64 + slack - trailing;
    if lo <= hi {
        wanted.clamp(lo, hi).round() as i32
    } else {
        // Swift's inverted-range clamp returns the AppKit lower limit. AppKit
        // y grows upwards, so vertical edges map that limit to physical hi.
        (if vertical { hi } else { lo }).round() as i32
    }
}

/// How far the taskbar (or anything else outside the work area) covers each side of a window at
/// (x, y, ww, wh), in physical pixels: top, right, bottom, left. `edge_origin` keeps the pill itself
/// out of the taskbar, so what is left here is the window's other three sides — an upright notch is
/// taller than the work area is on a short screen — and the hover card is what the page moves.
fn work_insets(s: &Screen, x: i32, y: i32, ww: i32, wh: i32) -> [i32; 4] {
    let (wx, wy, waw, wah) = s.work;
    [
        (wy - y).clamp(0, wh),
        ((x + ww) - (wx + waw)).clamp(0, ww),
        ((y + wh) - (wy + wah)).clamp(0, wh),
        (wx - x).clamp(0, ww),
    ]
}

/// The last insets pushed to the page, in its CSS px, for a page that asks before it was listening.
/// Pins the notch to the configured edge of the configured monitor.
/// The notch window's logical size for an edge.
///
/// Upright on the left and right, the pill is a column and 360 wide is plenty; its length is what
/// needs room, hence `NOTCH_LONG`. Lying flat on the top and bottom it is a row: six 44 px rings,
/// their gaps, the padding, both fillets and the settings orb come to about 504 px, so a 360 px
/// window clipped the pill once a fifth provider was on. It is square, because the card opens above
/// or below the pill there instead of beside it, and so needs the pill's own depth on top of its
/// height — at 520 a stale Antigravity card scrolled.
pub fn notch_window_size(edge: &str) -> (f64, f64) {
    if config::edge_is_vertical(edge) {
        (NOTCH_W, NOTCH_LONG)
    } else {
        (NOTCH_LONG, NOTCH_LONG)
    }
}

/// Swift NotchGeometry keeps the drawn notch on the screen; the transparent tooltip margins
/// may extend beyond it. Clamping the whole panel prevented placement near either end of an edge.
fn content_edge_origin(
    s: &Screen,
    edge: &str,
    ww: i32,
    wh: i32,
    ratio: f64,
    shape: Option<f64>,
    extents: (f64, f64),
) -> (i32, i32) {
    let (ax, ay, aw, ah) = s.area();
    let along = |start: i32, span: i32, len: i32| {
        visible_along_origin(
            start as f64 + span as f64 * ratio - len as f64 / 2.0,
            start, span, len, shape, extents.0, extents.1, config::edge_is_vertical(edge),
        )
    };
    match edge {
        "left" => (ax, along(ay, ah, wh)),
        "top" => (along(ax, aw, ww), ay),
        "bottom" => (along(ax, aw, ww), ay + ah - wh),
        _ => (ax + aw - ww, along(ay, ah, wh)),
    }
}

/// Content measurement is accepted only from the notch, never from a settings/web login window.
#[tauri::command]
async fn set_notch_content(
    app: AppHandle,
    window: tauri::WebviewWindow,
    mut content: notch_layout::Content,
) -> Result<(), String> {
    if !native_notch::is_notch_label(window.label()) || !content.valid() {
        return Err("invalid notch content measurement".into());
    }
    #[cfg(target_os = "macos")]
    {
        let (tx, mut rx) = tauri::async_runtime::channel(1);
        app.run_on_main_thread(move || {
            notch_layout::measure_card_text_on_main_thread(&mut content);
            let _ = tx.try_send(content);
        }).map_err(|e| e.to_string())?;
        content = rx.recv().await.ok_or_else(|| "Could not measure notch card text".to_string())?;
    }
    let changed = {
        let runtime = native_notch::runtime(window.label());
        let mut current = runtime.lock().unwrap();
        if current.content.as_ref() == Some(&content) {
            false
        } else {
            current.content = Some(content);
            true
        }
    };
    if changed {
        place_notch(&app);
    }
    Ok(())
}

pub fn place_notch(app: &AppHandle) {
    let target = target_screen(app);
    for w in app
        .webview_windows()
        .values()
        .filter(|w| native_notch::is_notch_label(w.label()))
    {
        let mon = native_notch::runtime(w.label())
            .lock()
            .unwrap()
            .screen
            .clone()
            .or_else(|| target.clone());
        if let Some(mon) = mon {
            place_notch_on(app, w, &mon);
        }
    }
}

fn place_notch_on(app: &AppHandle, w: &tauri::WebviewWindow, mon: &Screen) {
    let scale = w.scale_factor().unwrap_or(1.0);
    // Two monitors at different scales (150 % and 200 % in practice): the physical size can
    // end up converted with the *other* monitor's scale factor depending on where the window
    // is created and then moved, leaving the WebView ~256 logical px wide instead of 340.
    // So the physical size is pinned straight from mon.scale_factor() before placing the
    // window; if it still reports a different scale afterwards, it is pinned once more.
    let ms = mon.scale;
    let size = ui_scale(app);
    // Read here, not with the ratio below, because the window's shape depends on it.
    let (edge, show_move) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (config::edge_or_right(&c.notch_edge), c.show_move_handle)
    };
    let placement = native_notch::runtime(w.label()).lock().unwrap().edge_transition.observe(&edge);
    match placement {
        edge_transition::Placement::Wait => return,
        edge_transition::Placement::Fade(generation) => {
            let _ = app.emit_to(w.label(), "notch_edge_prepare", serde_json::json!({
                "generation": generation, "native": cfg!(target_os = "macos")
            }));
            // A lost WebView callback must not leave the panel invisible forever.
            // The generation also prevents an old timeout revealing a newer crossing.
            let app = app.clone();
            let label = w.label().to_owned();
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(700));
                let handle = app.clone();
                let _ = handle.run_on_main_thread(move || {
                    complete_edge_fade(&app, &label, generation);
                    if reveal_edge_transition(&app, &label, generation) {
                        applog("notch edge: folded paint acknowledgement timed out");
                        let _ = app.emit_to(&label, "notch_edge_fallback", generation);
                    }
                });
            });
            return;
        }
        edge_transition::Placement::Place => {}
    }
    let (content, hardware) = {
        let runtime = native_notch::runtime(w.label());
        let mut current = runtime.lock().unwrap();
        let screen_key = (mon.x, mon.y, mon.w, mon.h);
        if current.geometry_screen != Some(screen_key) {
            current.geometry_screen = Some(screen_key);
            current.hardware_notch = None;
        }
        (current.content.clone(), current.hardware_notch)
    };
    let layout = content.map(|c| notch_layout::calculate(&edge, c, mon.h as f64 / ms, size, hardware));
    let (width, height) = layout
        .map(|l| (l.width, l.height))
        .unwrap_or_else(|| notch_window_size(&edge));
    if let Some(layout) = layout {
        let _ = app.emit_to(w.label(), "notch_layout", layout);
    }
    // Never taller or wider than the screen: Large on a small, highly scaled display can ask for more
    let target = tauri::PhysicalSize::new(
        (width * ms * size).ceil() as u32,
        (height * ms * size).ceil() as u32,
    );
    let _ = w.set_size(target);
    zoom_notch(&w, ms, size);
    // Position from the window's measured physical size — deriving it from the scale factor
    // pushed the window past the right edge at 125 % / 150 % (the ring's right side was clipped).
    let (ww, wh) = w
        .outer_size()
        .map(|s| (s.width as i32, s.height as i32))
        .unwrap_or((target.width as i32, target.height as i32));
    let ratio = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        c.along(&edge)
    };
    let shape = layout.map(|l| l.shape_length * ms * size);
    let extents = if shape.is_some() {
        handle_extents(&edge, size, ms, show_move, hardware)
    } else {
        (0.0, 0.0)
    };
    let (x, y) = content_edge_origin(&mon, &edge, ww, wh, ratio, shape, extents);
    let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    let mut placed = (x, y, ww, wh);
    if w.outer_size()
        .map(|s| s.width != target.width)
        .unwrap_or(false)
    {
        let _ = w.set_size(target);
        let (x, y) = content_edge_origin(
            &mon,
            &edge,
            target.width as i32,
            target.height as i32,
            ratio,
            shape,
            extents,
        );
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
        placed = (x, y, target.width as i32, target.height as i32);
    }
    // The page mirrors itself for the edge it is on; it cannot know that on its own.
    let _ = app.emit_to(w.label(), "notch_edge", &edge);
    // Nor can it see the taskbar: a card opened near the bottom of a side edge slid under it.
    // The page is `size` × the monitor scale smaller than the window in CSS px.
    let css = (ms * size).max(0.01);
    let insets = work_insets(&mon, placed.0, placed.1, placed.2, placed.3).map(|v| v as f64 / css);
    native_notch::runtime(w.label()).lock().unwrap().insets = insets;
    let _ = app.emit_to(w.label(), "notch_insets", insets);
    // Placement log line: the first thing to check when the notch is not visible. Appended, not
    // overwritten (#240) — place_notch runs after every drag as well as at startup, and a
    // truncating write wiped the rest of the session's diagnostic trail on every drag.
    applog(&format!(
            "notch placed build={BUILD}: edge={edge} pos=({x},{y}) size=({ww}x{wh}) inner={:?} win_scale={scale} mon_scale={ms} notch_size={size} monitor={:?}=({},{} {}x{}) work={:?} card_insets_css={insets:?}",
            w.inner_size().map(|s| (s.width, s.height)).unwrap_or((0, 0)),
            mon.name,
            mon.x,
            mon.y,
            mon.w,
            mon.h,
            mon.work
        ));
    native_notch::notify_geometry(app, w.label());
}

fn complete_edge_fade(app: &AppHandle, label: &str, generation: u32) {
    let Some(window) = app.get_webview_window(label) else { return; };
    let edge = native_notch::runtime(label).lock().unwrap().edge_transition.land(generation);
    let Some(edge) = edge else { return; };
    let screen = native_notch::runtime(label).lock().unwrap().screen.clone()
        .or_else(|| target_screen(app));
    if let Some(screen) = screen { place_notch_on(app, &window, &screen); }
    let _ = app.emit_to(label, "notch_edge_arrived", serde_json::json!({"generation": generation, "edge": edge}));
}

fn reveal_edge_transition(app: &AppHandle, label: &str, generation: u32) -> bool {
    let Some(window) = app.get_webview_window(label) else { return false; };
    if !native_notch::runtime(label).lock().unwrap().edge_transition.reveal(generation) { return false; }
    native_notch::reveal_edge(&window);
    true
}

#[tauri::command]
fn notch_edge_fade(app: AppHandle, window: tauri::WebviewWindow, generation: u32) {
    #[cfg(target_os = "macos")]
    native_notch::fade_edge(&app, window.label(), generation);
    #[cfg(not(target_os = "macos"))]
    {
        let label = window.label().to_owned();
        let handle = app.clone();
        let _ = handle.run_on_main_thread(move || {
            if native_notch::runtime(&label).lock().unwrap().edge_transition.begin_fade(generation) {
                complete_edge_fade(&app, &label, generation);
            }
        });
    }
}

#[tauri::command]
async fn notch_edge_visible(app: AppHandle, window: tauri::WebviewWindow, generation: u32) -> bool {
    let (send, receive) = tokio::sync::oneshot::channel();
    let label = window.label().to_owned();
    let handle = app.clone();
    let _ = handle.run_on_main_thread(move || {
        let _ = send.send(reveal_edge_transition(&app, &label, generation));
    });
    receive.await.unwrap_or(false)
}

/// How often the work area is re-read. It only changes by hand — the taskbar moved to another edge,
/// resized, or switched to auto-hide — so a second late is not noticeable.
const WORK_AREA_POLL_MS: u64 = 1000;

/// Puts the notch back on its edge when the work area moves under it.
///
/// Nothing hands us `WM_SETTINGCHANGE`, and the notch is placed against the work area now, so
/// moving the taskbar to another edge would otherwise leave the notch a taskbar's width from the
/// edge it is pinned to, floating in the gap the old taskbar left. Polled rather than hooked,
/// because hooking it means subclassing a window we do not own to catch something that happens
/// once in a session.
fn start_work_area_watch(app: AppHandle) {
    std::thread::spawn(move || {
        let geometry = |s: Screen| (s.x, s.y, s.w, s.h, s.scale.to_bits(), s.work);
        let mut last = target_screen(&app).map(geometry);
        let mut last_all: Vec<_> = screens(&app).into_iter().map(geometry).collect();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(WORK_AREA_POLL_MS));
            if DRAGGING.load(std::sync::atomic::Ordering::SeqCst) {
                continue;
            }
            let windows = front_window::sample();
            let screen = target_screen(&app);
            let fullscreen = screen.as_ref().is_some_and(|s| {
                windows
                    .iter()
                    .any(|w| w.covers(front_window::screen_rect(s), cfg!(target_os = "macos")))
            });
            let _ = front_window::set_fullscreen(fullscreen);
            for panel in app
                .webview_windows()
                .values()
                .filter(|w| native_notch::is_notch_label(w.label()))
            {
                let panel_screen = native_notch::runtime(panel.label())
                    .lock()
                    .unwrap()
                    .screen
                    .clone()
                    .or_else(|| screen.clone());
                let local_fullscreen = panel_screen.as_ref().is_some_and(|s| {
                    windows
                        .iter()
                        .any(|w| w.covers(front_window::screen_rect(s), cfg!(target_os = "macos")))
                });
                let runtime = native_notch::runtime(panel.label());
                let mut rt = runtime.lock().unwrap();
                if rt.fullscreen != local_fullscreen {
                    rt.fullscreen = local_fullscreen;
                    drop(rt);
                    let _ = app.emit_to(panel.label(), "fullscreen", local_fullscreen);
                }
            }
            let now = screen.map(geometry);
            let all_now: Vec<_> = screens(&app).into_iter().map(geometry).collect();
            if all_now != last_all {
                last_all = all_now;
                native_notch::schedule_reconcile(&app);
                let _ = app.emit_to("settings", "monitors_changed", ());
            }
            if now != last {
                last = now;
                place_notch(&app);
            }
        }
    });
}

/// Older entry point name still used by tray.rs. Recentre puts the notch in the middle of the edge it
/// is on, and only sends it home to the primary monitor's right edge when the screen it was on is
/// gone — which is the case the button exists for, and the one where its own edge means nothing.
pub fn reset_bar(app: &AppHandle) {
    let stranded = {
        let st = app.state::<AppState>();
        let want = st.cfg.lock().unwrap().notch_monitor.clone();
        want.is_some_and(|name| {
            !screens(app)
                .iter()
                .any(|s| screen_id_matches(s, &name))
        })
    };
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if stranded {
            c.notch_edge = "right".into();
            c.notch_monitor = None;
        }
        // Only the edge it is on: the others keep wherever they were left, as on the Mac
        let edge = config::edge_or_right(&c.notch_edge);
        c.set_along(&edge, 0.5);
        config::save(&c);
    }
    place_notch(app);
}

/// Drag. The page calls this once after an Alt-press on the pill moves more than 4 px; from then on
/// a Rust thread follows the system cursor (WebView mousemove is unreliable once the window itself
/// starts moving). Only the axis along the notch's edge follows it: this slides the notch along the
/// edge it is on and never takes it to another, which is the move handle's job — the Mac's ⌥-drag
/// (`NotchWindowController.dragged`). Releasing it saves that place for that edge alone.
static DRAGGING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[cfg(windows)]
fn left_button_down() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}
#[cfg(not(windows))]
fn left_button_down() -> bool {
    platform::left_button_down()
}

/// Which edge a point belongs to: the screen split into four triangles about its centre, as on the
/// Mac. Nearest-edge rather than hit testing the zones, which are thin — landing inside a 70 px strip
/// would be threading a needle.
pub(crate) fn edge_at(x: f64, y: f64, w: f64, h: f64) -> &'static str {
    let (left, right, top, bottom) = (x, w - x, y, h - y);
    let nearest = left.min(right).min(top).min(bottom);
    if nearest == right {
        "right"
    } else if nearest == left {
        "left"
    } else if nearest == top {
        "top"
    } else {
        "bottom"
    }
}

/// The move handle changes only the edge. Display preference belongs to the
/// separate monitor setting, and a release on the same edge is a no-op.
fn apply_move_edge(config: &mut config::Config, target: &str) -> bool {
    if config::edge_or_right(&config.notch_edge) == target {
        return false;
    }
    config.notch_edge = target.to_string();
    true
}

/// Carrying the notch by its move handle: the zones go up, the pointer picks one, and releasing
/// hands it over. The notch itself stays where it is until then — what is being chosen is a place on
/// the screen, not a distance moved, so nothing follows the pointer.
///
/// `depth` and `length` are the pill's own measurements standing upright, in the notch page's CSS px.
#[tauri::command]
fn begin_move(app: AppHandle, window: tauri::WebviewWindow, depth: f64, length: f64) {
    if !native_notch::is_notch_label(window.label()) {
        return;
    }
    if DRAGGING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let label = window.label().to_string();
        let done = |app: &AppHandle| {
            dropzones::hide(app);
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            let _ = app.emit_to(&label, "move_end", ());
        };
        let Some(start) = native_notch::runtime(&label)
            .lock()
            .unwrap()
            .screen
            .clone()
            .or_else(|| target_screen(&app))
        else {
            done(&app);
            return;
        };
        let from = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            config::edge_or_right(&c.notch_edge)
        };
        // The overlay is at the monitor's own scale; the notch page is that scale times its size
        let size = ui_scale(&app);
        let (ax, ay, aw, ah) = start.area();
        let mut zones = dropzones::Zones {
            w: aw as f64 / start.scale,
            h: ah as f64 / start.scale,
            depth: depth * size,
            length: length * size,
            target: from.clone(),
        };
        dropzones::show(&app, &start, &zones);
        let mut target = from.clone();
        while left_button_down() {
            if let Ok(cur) = app.cursor_position() {
                // Match DropZoneOverlay(screen:): the overlay and its coordinates stay on
                // the screen where the handle was pressed, even if the pointer crosses over.
                let next = edge_at(cur.x - ax as f64, cur.y - ay as f64, aw as f64, ah as f64);
                if next != target {
                    target = next.to_string();
                    zones.target = target.clone();
                    dropzones::retarget(&app, &zones);
                    let _ = app.emit_to(&label, "move_target", &target);
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(16));
        }
        applog(&format!("notch carry: {from} -> {target} on {:?}", start.name));
        if target != from {
            let changed = {
                let st = app.state::<AppState>();
                let mut c = st.cfg.lock().unwrap();
                let changed = apply_move_edge(&mut c, &target);
                if changed { config::save(&c); }
                changed
            };
            if changed {
                place_notch(&app);
            }
        }
        done(&app);
    });
}

#[tauri::command]
fn drag_begin(app: AppHandle, w: tauri::WebviewWindow) {
    if !native_notch::is_notch_label(w.label()) {
        return;
    }
    if DRAGGING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        let (Ok(start_cur), Ok(start_pos), Ok(size)) =
            (app.cursor_position(), w.outer_position(), w.outer_size())
        else {
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let Some(mon) = native_notch::runtime(w.label())
            .lock()
            .unwrap()
            .screen
            .clone()
            .or_else(|| target_screen(&app))
        else {
            DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
            return;
        };
        let (edge, show_move) = {
            let st = app.state::<AppState>();
            let c = st.cfg.lock().unwrap();
            (config::edge_or_right(&c.notch_edge), c.show_move_handle)
        };
        let vertical = config::edge_is_vertical(&edge);
        let (ww, wh) = (size.width as i32, size.height as i32);
        let scale = ui_scale(&app);
        let (content, hardware) = {
            let runtime = native_notch::runtime(w.label());
            let current = runtime.lock().unwrap();
            (current.content.clone(), current.hardware_notch)
        };
        let shape = content.map(|c| {
            notch_layout::calculate(&edge, c, mon.h as f64 / mon.scale, scale, hardware).shape_length
                * mon.scale * scale
        });
        let extents = if shape.is_some() {
            handle_extents(&edge, scale, mon.scale, show_move, hardware)
        } else {
            (0.0, 0.0)
        };
        // The visible shape and both handle hot circles stay on the full display;
        // transparent card slack may run past either end, as in NotchGeometry.panelFrame.
        let (ax, ay, aw, ah) = mon.area();
        let (mut last_x, mut last_y) = (start_pos.x, start_pos.y);
        let mut moved = false;
        loop {
            if !left_button_down() {
                break;
            }
            if let Ok(cur) = app.cursor_position() {
                let (nx, ny) = if vertical {
                    let y = visible_along_origin(
                        start_pos.y as f64 + cur.y - start_cur.y,
                        ay, ah, wh, shape, extents.0, extents.1, true,
                    );
                    (start_pos.x, y)
                } else {
                    let x = visible_along_origin(
                        start_pos.x as f64 + cur.x - start_cur.x,
                        ax, aw, ww, shape, extents.0, extents.1, false,
                    );
                    (x, start_pos.y)
                };
                if nx != last_x || ny != last_y {
                    last_x = nx;
                    last_y = ny;
                    moved = true;
                    let _ = w.set_position(tauri::PhysicalPosition::new(nx, ny));
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(8));
        }
        if moved {
            let along = if vertical {
                along_at(last_y, wh, ay, ah)
            } else {
                along_at(last_x, ww, ax, aw)
            };
            {
                let st = app.state::<AppState>();
                let mut c = st.cfg.lock().unwrap();
                c.set_along(&edge, along);
                config::save(&c);
            }
            applog(&format!("notch slid along {edge} to {along:.3}"));
            place_notch(&app);
        }
        DRAGGING.store(false, std::sync::atomic::Ordering::SeqCst);
        let _ = app.emit_to(w.label(), "drag_end", moved);
    });
}
pub fn place_bar(app: &AppHandle) {
    place_notch(app);
}
pub fn toggle_drag(app: &AppHandle) {
    // The notch stays welded to the edge; kept as a no-op for the tray menu code path
    let _ = app;
}

pub fn apply_lang(app: &AppHandle, lang: &str) {
    let changed = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        let changed = c.lang != lang;
        if changed {
            c.lang = lang.to_string();
            config::save(&c);
        }
        changed
    };
    // Through refresh_menu, which makes sure the swap happens on the main thread: doing it from the
    // settings window's thread left the tray with a menu that would never open again.
    tray::refresh_menu(app);
    broadcast(app);
    if changed {
        // Swift UsageStore re-reads on a language change because parsed window labels are
        // archived with the reading; repainting alone can leave an old-language label.
        // Account discovery stays off the settings IPC thread.
        let app = app.clone();
        std::thread::spawn(move || {
            let _ = refresh_all_tracked(&app);
        });
    }
}

// ---------------- commands ----------------

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> state::Snapshot {
    let store = state.store.lock().unwrap();
    let cfg = state.cfg.lock().unwrap();
    store.snapshot_filtered(
        &cfg.lang,
        &resolved_lang(&cfg.lang),
        i18n::clock_24h(),
        false,
        &cfg.providers.disabled,
    )
}

#[tauri::command]
fn get_usage(app: AppHandle) -> usage::UsageSnapshot {
    snapshot_of(&app, "claude")
}

#[tauri::command]
fn claude_sign_in(id: Option<String>) -> Result<(), String> {
    claude_auth::start_login_for(id.as_deref())
}

#[tauri::command]
fn get_claude_auth() -> claude_auth::AuthState {
    claude_auth::state()
}

/// Asks one provider to read again, and says whether a reading is on its way. Claude's rate-limit
/// wait stands, as on the Mac: asking early spends a request and can double the wait.
pub(crate) fn refresh_provider(app: &AppHandle, provider: &str) -> bool {
    if !providers::enabled(app, provider) || snapshot_of(app, provider).backoff_until > now_ms() {
        return false;
    }
    match provider {
        "claude" => usage::request_profile_refresh("claude"),
        "codex" => codex::request_refresh(),
        "cursor" => cursor::request_refresh(),
        "grok" => grok::request_refresh(),
        "gemini" => antigravity::request_refresh(),
        "glm" => glm::request_refresh(),
        id if id.starts_with("custom-endpoint-") => {
            let app = app.clone();
            let id = id.trim_start_matches("custom-endpoint-").to_string();
            tauri::async_runtime::spawn(async move {
                let provider = format!("custom-endpoint-{id}");
                let _ = custom_endpoint::probe_custom_endpoint(app, id).await;
                refresh::complete(&provider);
            });
        }
        _ => return providers::request(provider),
    }
    true
}

pub(crate) fn refresh_all(app: &AppHandle) {
    let _ = refresh_all_tracked(app);
    let a = app.clone();
    std::thread::spawn(move || reload_glyphs(&a));
}
/// Arm before scheduling: even an immediate cached/error reply completes this
/// generation. The phone uses the same read path as the desktop's Refresh All.
pub(crate) fn refresh_all_tracked(app: &AppHandle) -> Vec<(String, u64)> {
    let ids: std::collections::BTreeSet<_> = TRAY_PROVIDER_IDS
        .iter()
        .map(|id| id.to_string())
        .chain(
            providers::get_providers(app.clone())
                .into_iter()
                .map(|p| p.id),
        )
        .collect();
    ids.into_iter()
        .filter_map(|id| {
            let generation = refresh::generation(&id);
            let accepted = refresh_provider(app, &id);
            (accepted && snapshot_of(app, &id).status != "absent").then_some((id, generation))
        })
        .collect()
}

/// A click on a ring refetches that provider, as on the Mac.
#[tauri::command]
fn refresh_ring(app: AppHandle, provider: String) -> bool {
    refresh_provider(&app, &provider)
}

#[tauri::command]
fn get_antigravity(app: AppHandle) -> usage::UsageSnapshot {
    snapshot_of(&app, "gemini")
}

#[tauri::command]
fn get_glm(app: AppHandle) -> usage::UsageSnapshot {
    snapshot_of(&app, "glm")
}

#[tauri::command]
fn get_activity(state: tauri::State<AppState>) -> Vec<activity::Activity> {
    state.activity.lock().unwrap().clone()
}

#[tauri::command]
fn get_glyphs(state: tauri::State<AppState>) -> std::collections::HashMap<String, glyphs::Glyph> {
    state.glyphs.lock().unwrap().clone()
}

/// Collects the glyphs again and pushes them to the page (tray refresh, or the user just dropped in an override)
pub fn reload_glyphs(app: &AppHandle) {
    let st = app.state::<AppState>();
    let endpoints = st.cfg.lock().unwrap().custom_endpoints.clone();
    let mut m = glyphs::collect();
    glyphs::collect_custom(&endpoints, &mut m);
    *st.glyphs.lock().unwrap() = m.clone();
    let _ = app.emit("glyphs", &m);
}

#[tauri::command]
fn open_data_dir() {
    let dir = config::config_path()
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_default();
    let _ = std::fs::create_dir_all(glyphs::user_dir());
    let _ = platform::open(dir.as_os_str());
}

#[tauri::command]
fn get_grok(app: AppHandle) -> usage::UsageSnapshot {
    snapshot_of(&app, "grok")
}

#[tauri::command]
fn get_cursor(app: AppHandle) -> usage::UsageSnapshot {
    snapshot_of(&app, "cursor")
}

#[tauri::command]
fn get_codex(app: AppHandle) -> usage::UsageSnapshot {
    snapshot_of(&app, "codex")
}

/// A provider's usage page, and the host the notch menu names it by.
pub(crate) fn provider_page(provider: &str) -> Option<(&'static str, &'static str)> {
    Some(match provider {
        "claude" => ("https://claude.ai/settings/usage", "claude.ai"),
        "codex" => ("https://chatgpt.com/#settings/Account", "chatgpt.com"),
        "cursor" => ("https://cursor.com/dashboard", "cursor.com"),
        "grok" => ("https://grok.com/?_s=usage", "grok.com"),
        "gemini" => ("https://antigravity.google", "antigravity.google"),
        "glm" => ("https://z.ai/manage-apikey/apikey-list", "z.ai"),
        _ => return None,
    })
}

pub(crate) fn open_provider_page(provider: &str) {
    let Some((url, _)) = provider_page(provider) else {
        return;
    };
    let _ = platform::open(std::ffi::OsStr::new(url));
}

/// Hot rectangles in **physical pixels**, window-relative, as x,y,w,h: the pill, plus the card
/// while it is open. The page converts by its own devicePixelRatio before reporting, so no scale
/// conversion happens here — WebView2's DPR and the window's scale_factor can disagree (see
/// report_dpr).
///
/// Empty means click-through: before the page has reported, one lost click on the notch beats
/// eating every click aimed at the window behind it.
#[tauri::command]
fn set_hot(window: tauri::WebviewWindow, rects: Vec<[f64; 4]>, expanded: bool) {
    let runtime = native_notch::runtime(window.label());
    let mut rt = runtime.lock().unwrap();
    rt.hot = rects;
    rt.expanded = expanded;
    drop(rt);
    if expanded {
        antigravity::request_hover_refresh();
    }
}

/// Setting `WS_EX_TRANSPARENT` by hand instead looks like it should work, and does not: it applies
/// to the notch window, but WebView2 keeps child HWNDs that hit-testing descends into and they
/// never get the bit. `WS_EX_LAYERED` is what makes the window answer as one surface, so the helper
/// that sets both is the only route. Clearing it again is safe — the notch is not otherwise layered
/// (its transparency is DWM composition), so the window returns to the styles it had.
fn set_click_through(w: &tauri::WebviewWindow, on: bool) {
    let _ = w.set_ignore_cursor_events(on);
}

/// The WebView zoom currently applied (1.0 = uncorrected)
/// Keeps the notch page at its designed 360 × 520 CSS px in a window `size` times larger: the
/// WebView zooms by `size` on top of whatever brings its DPR back to the monitor's scale, so the
/// rings, text and hover card scale together, as the Mac's size does.
fn zoom_notch(w: &tauri::WebviewWindow, monitor_scale: f64, size: f64) {
    let runtime = native_notch::runtime(w.label());
    let update = {
        let mut rt = runtime.lock().unwrap();
        let base = if rt.base_dpr > 0.0 { rt.base_dpr } else { monitor_scale };
        let target = monitor_scale * size / base;
        if (target - rt.zoom).abs() <= 0.001 {
            None
        } else {
            rt.zoom_seq = rt.zoom_seq.wrapping_add(1);
            Some((target, rt.zoom_seq))
        }
    };
    if let Some((target, seq)) = update {
        match w.set_zoom(target) {
            Ok(()) => {
                let mut rt = runtime.lock().unwrap();
                if rt.zoom_seq == seq { rt.zoom = target; }
            }
            Err(e) => applog(&format!("notch zoom failed: {e}")),
        }
    }
}

/// run.log never grows past this. The placement line used to rewrite the file on every drag,
/// which was the only thing that ever emptied it; appended instead, it needs a bound of its own.
const RUN_LOG_MAX_BYTES: u64 = 1024 * 1024;

pub fn applog(line: &str) {
    use std::io::Write;
    let log = config::config_path().with_file_name("run.log");
    // Past the cap the log starts again rather than growing for as long as the app runs.
    let full = std::fs::metadata(&log)
        .map(|m| m.len() > RUN_LOG_MAX_BYTES)
        .unwrap_or(false);
    let opened = if full {
        std::fs::File::create(&log)
    } else {
        std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log)
    };
    if let Ok(mut f) = opened {
        let _ = writeln!(f, "{line}");
    }
}

/// Root cause: with two monitors (150 % / 200 %) WebView2 picked a devicePixelRatio of 2.0 while
/// the window was sized for the primary monitor's 1.5, so the page was 255 CSS px wide instead of
/// the designed 340 and every coordinate conversion was off (the watchdog misfired and the card
/// flashed away). Fix: the page reports its DPR, and when it differs from the primary monitor's
/// scale, set_zoom pulls the effective DPR back to that scale, restoring the 340 px width.
///
/// `settled` is true when the report comes at the end of a burst of resizes rather than partway
/// through one, which is what a landing on another screen waits for before it shows the notch.
#[tauri::command]
fn report_dpr(
    app: AppHandle,
    win: tauri::WebviewWindow,
    dpr: f64,
    w: f64,
    h: f64,
    settled: Option<bool>,
) {
    let runtime = native_notch::runtime(win.label());
    let screen = { runtime.lock().unwrap().screen.clone() };
    let want = screen
        .or_else(|| target_screen(&app))
        .map(|s| s.scale)
        .unwrap_or_else(|| win.scale_factor().unwrap_or(1.0))
        * ui_scale(&app);
    // Never hold WindowRuntime across WebView calls: set_zoom may synchronously wait for the UI
    // thread, which itself reports DPR and needs the same runtime mutex.
    let (previous_zoom, target, correction, reveal) = {
        let mut rt = runtime.lock().unwrap();
        let base = if rt.zoom > 0.0 { dpr / rt.zoom } else { dpr };
        rt.base_dpr = base;
        let target = if base > 0.0 { want / base } else { 1.0 };
        let previous_zoom = rt.zoom;
        let correction = if (dpr - want).abs() > 0.02
            && (target - rt.zoom).abs() > 0.01
            && (0.25..=4.0).contains(&target)
            && rt.dpr_corrections < 3
        {
            rt.dpr_corrections += 1;
            rt.zoom_seq = rt.zoom_seq.wrapping_add(1);
            Some(rt.zoom_seq)
        } else { None };
        let reveal = if settled == Some(true) && correction.is_none() && rt.landing != 0 {
            rt.landing = 0;
            true
        } else { false };
        (previous_zoom, target, correction, reveal)
    };
    applog(&format!(
        "dpr report: dpr={dpr:.3} viewport={w:.0}x{h:.0} want_dpr={want:.3} zoom_applied={:.3} -> target_zoom={target:.3}",
        previous_zoom
    ));
    // Oscillation guard: at most three corrections per process (if the DPR does not follow the zoom, stop chasing it)
    if let Some(seq) = correction {
        match win.set_zoom(target) {
            Ok(()) => {
                {
                    let mut rt = runtime.lock().unwrap();
                    if rt.zoom_seq == seq { rt.zoom = target; }
                }
                applog(&format!("dpr correction: set_zoom({target:.3}) ok"));
            }
            Err(e) => applog(&format!("dpr correction failed: {e}")),
        }
        // A failed correction must not leave a settled landing hidden indefinitely.
        if settled == Some(true) {
            let should_reveal = {
                let mut rt = runtime.lock().unwrap();
                if rt.zoom_seq == seq && rt.landing != 0 && (rt.zoom - target).abs() > 0.01 {
                    rt.landing = 0;
                    true
                } else { false }
            };
            if should_reveal { let _ = app.emit_to(win.label(), "notch_reveal", ()); }
        }
    }
    // A correction resizes the page once more, and its own settled report follows; the landing is
    // shown on the first settled report that needed none
    if reveal { let _ = app.emit_to(win.label(), "notch_reveal", ()); }
}

/// Slack around every hot rectangle: this is sampled on a timer, so a cursor arriving at the pill
/// has to count as arrived slightly early, or a quick click lands between two polls while the
/// window is still click-through and goes to whatever is behind it.
const HOT_PAD: f64 = 10.0;

/// Is the cursor on something the window is there for? `window` is the outer size in physical
/// pixels, or None when it could not be read.
fn cursor_in_hot(rects: &[[f64; 4]], lx: f64, ly: f64, window: Option<(f64, f64)>) -> bool {
    if rects.is_empty() {
        return false;
    }
    let in_window = window
        .map(|(w, h)| lx >= 0.0 && ly >= 0.0 && lx < w && ly < h)
        .unwrap_or(true);
    if !in_window {
        return false;
    }
    rects.iter().any(|r| {
        lx >= r[0] - HOT_PAD
            && ly >= r[1] - HOT_PAD
            && lx < r[0] + r[2] + HOT_PAD
            && ly < r[1] + r[3] + HOT_PAD
    })
}

/// Was 150 ms, when this only decided whether the card stayed up. It now also gates whether a click
/// reaches the notch, and at 150 ms a click arriving in the wrong sample went to the window behind.
const WATCHDOG_MS: u64 = 50;
/// Kept at the original 300 ms rather than falling out of the faster poll, which would make the
/// card twitchy.
const LEAVE_MS: u64 = 300;

/// WebView2's mouseleave is unreliable inside a NOACTIVATE transparent window — a cursor that
/// leaves quickly often produces no WM_MOUSELEAVE, and the card stays up. Rather than trust DOM
/// events, the Rust side watches the system cursor and emits pointer_left once it is outside; the
/// page collapses after its 250 ms grace period. "Outside the window" is not the test, though: the
/// window is mostly transparent, so the cursor is compared against the hot rectangles the page
/// reports (pill, card, and the gap between them).
///
/// It also gates click-through (#106), which is why it runs whether or not the card is open. That
/// ordering is load-bearing: the window ignores the cursor while it is click-through, so the page
/// gets no mousemove out there and cannot see the pointer arriving. This loop does, and hands the
/// window its input back in time for the page to open the card.
pub(crate) fn start_pointer_watchdog(app: AppHandle, label: String) {
    std::thread::spawn(move || {
        let runtime = native_notch::runtime(&label);
        let need = (LEAVE_MS / WATCHDOG_MS).max(1) as u8;
        let mut miss = 0u8;
        // Last value pushed: this changes only when the cursor crosses an edge
        let mut click_through: Option<bool> = None;
        loop {
            std::thread::sleep(std::time::Duration::from_millis(WATCHDOG_MS));
            let Some(w) = app.get_webview_window(&label) else {
                break;
            };
            let (Ok(pos), Ok(cur)) = (w.outer_position(), app.cursor_position()) else {
                continue;
            };
            let (rects, expanded) = {
                let rt = runtime.lock().unwrap();
                if rt.edge_transition.pending() { (Vec::new(), false) }
                else { (rt.hot.clone(), rt.expanded) }
            };
            // Cursor position relative to the window's top-left, in physical pixels; the hot rectangles are physical too, so no scale conversion
            let lx = cur.x - pos.x as f64;
            let ly = cur.y - pos.y as f64;
            let size = w
                .outer_size()
                .ok()
                .map(|s| (s.width as f64, s.height as f64));
            let inside = cursor_in_hot(&rects, lx, ly, size);

            if click_through != Some(!inside) {
                set_click_through(&w, !inside);
                click_through = Some(!inside);
                // Show on hover opens on this and folds a moment after it goes false. The page cannot
                // tell on its own: once click-through is back on, it is sent nothing at all.
                let _ = app.emit_to(&label, "notch_pointer", inside);
                applog(&format!(
                    "click-through {} at cursor_rel=({lx:.0},{ly:.0}) rects={rects:?}",
                    if inside {
                        "off (cursor on the notch)"
                    } else {
                        "on (cursor elsewhere)"
                    }
                ));
            }

            static LOGGED: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            if LOGGED.fetch_add(1, std::sync::atomic::Ordering::Relaxed) < 12 {
                applog(&format!(
                    "watchdog: cursor_rel=({lx:.0},{ly:.0}) inside={inside} rects={rects:?} winpos=({},{})",
                    pos.x, pos.y
                ));
            }

            if !expanded {
                miss = 0;
                continue;
            }
            if inside {
                miss = 0;
            } else {
                miss += 1;
                if miss >= need {
                    miss = 0;
                    runtime.lock().unwrap().expanded = false;
                    let _ = app.emit_to(&label, "pointer_left", ());
                }
            }
        }
    });
}

/// Log channel for the page: JS writes key diagnostics into run.log (if invoke itself fails, the page reports on screen instead)
#[tauri::command]
fn log_js(msg: String) {
    applog(&format!(
        "js: {}",
        msg.chars().take(600).collect::<String>()
    ));
}

#[tauri::command]
async fn focus_session(app: AppHandle, id: String) -> bool {
    // A row's ID is only a lookup key. Never accept a PID from the WebView,
    // and never focus a recycled Claude PID from an old hook/registry event.
    let claude = {
        let st = app.state::<AppState>();
        let store = st.store.lock().unwrap();
        store.focus_target(&id)
    };
    let ppid = claude.and_then(|(pid, born)|
        (claude_session_monitor::process_start_ms(pid) == Some(born)).then_some(pid));
    let activity_source = {
        let st = app.state::<AppState>();
        let disabled = st.cfg.lock().unwrap().providers.disabled.clone();
        let source = st.activity.lock().unwrap().iter()
            .find(|row| row.id == id && row.focusable && !disabled.contains(&row.provider))
            .map(|row| row.provider.clone());
        source
    };
    let ppid = ppid.or_else(|| match activity_source.as_deref() {
        Some("grok") => grok_activity::focus_target(&id),
        Some("kimi") => kimi_activity::focus_target(&id),
        _ => None,
    });
    #[cfg(target_os = "macos")]
    {
        let owner = if let Some(pid) = ppid {
            let (tx, mut rx) = tauri::async_runtime::channel(1);
            if app.run_on_main_thread(move || { let _ = tx.try_send(focus::owner_of(pid)); }).is_err() {
                return false;
            }
            let Some((owner_pid, bundle)) = rx.recv().await.flatten() else { return false };
            let _ = tauri::async_runtime::spawn_blocking(move || {
                let tty = focus::tty_of(pid);
                let cwd = focus::cwd_of(pid);
                terminal_tab_focus::select_tab(&bundle, pid, tty.as_deref(), cwd.as_deref())
            }).await;
            Some(owner_pid)
        } else if id == "claude-desktop-network" {
            tauri::async_runtime::spawn_blocking(focus::claude_desktop_pid).await.ok().flatten()
        } else { None };
        let Some(owner) = owner else { return false };
        let (tx, mut rx) = tauri::async_runtime::channel(1);
        if app.run_on_main_thread(move || { let _ = tx.try_send(focus::activate(owner)); }).is_err() {
            return false;
        }
        return rx.recv().await.unwrap_or(false);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        tauri::async_runtime::spawn_blocking(move || match ppid {
            Some(p) => focus::focus_terminal(p),
            None if id == "claude-desktop-network" => focus::focus_claude_desktop(),
            None => false,
        }).await.unwrap_or(false)
    }
}

#[tauri::command]
fn dismiss_session(app: AppHandle, id: String) {
    {
        let st = app.state::<AppState>();
        let mut store = st.store.lock().unwrap();
        store.dismiss(&id);
    }
    broadcast(&app);
}

#[tauri::command]
fn set_lang(app: AppHandle, lang: String) {
    apply_lang(&app, &lang);
}

// ---------------- notch size ----------------

#[tauri::command]
fn get_scale(app: AppHandle) -> f64 {
    ui_scale(&app)
}

/// Settings' Small, Medium or Large. The notch window is resized and zoomed around its centre.
#[tauri::command]
fn set_scale(app: AppHandle, scale: f64) -> f64 {
    let (value, changed) = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        let previous = c.appearance.effective_scale(c.scale);
        let mut next = c.clone();
        next.appearance.custom_scale = None;
        next.scale = config::snap_scale(scale);
        let value = next.scale;
        if let Err(error) = config::save_checked(&next) {
            applog(&format!("notch scale: {error}"));
            return previous;
        }
        *c = next;
        (value, (value - previous).abs() > f64::EPSILON)
    };
    place_notch(&app);
    if changed { peek_notch_for_size(&app); }
    value
}

/// Swift shows the resized notch for 1.2 seconds while a preset or custom slider is adjusted.
/// A standing Hide choice wins; the page owns the fold timer and pointer/pin arbitration.
pub(crate) fn peek_notch_for_size(app: &AppHandle) {
    let visible = app.state::<AppState>().cfg.lock().unwrap().notch_visible;
    if !visible { return; }
    for window in app.webview_windows().values()
        .filter(|window| native_notch::is_notch_label(window.label())) {
        let _ = window.show();
        let _ = app.emit_to(window.label(), "notch_peek", serde_json::json!({"seconds":1.2}));
    }
}

/// Where the weekly limit's ring sits, if it is drawn at all.
#[tauri::command]
fn get_weekly_ring(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.weekly_ring.clone()
}

/// Unknown values are refused rather than stored. The notch draws its own rings, so it is told.
#[tauri::command]
fn set_weekly_ring(app: AppHandle, placement: String) -> String {
    let value = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if ["off", "inside", "outside"].contains(&placement.as_str()) {
            c.weekly_ring = placement;
            config::save(&c);
        }
        c.weekly_ring.clone()
    };
    let _ = app.emit("weekly_ring", &value);
    value
}

// ---------------- tray icon readings ----------------

/// The tightest metered window, ties going to the lower id so the choice never flickers. A `count`
/// window (Antigravity's requests today) has no published denominator, so it is never a candidate.
fn tightest<'a>(
    windows: impl Iterator<Item = &'a usage::LimitWindow>,
) -> Option<&'a usage::LimitWindow> {
    windows
        .filter(|w| w.count.is_none())
        .max_by(|a, b| a.used.total_cmp(&b.used).then_with(|| b.id.cmp(&a.id)))
}

/// The window a provider's ring shows, declared per provider as the macOS providers declare
/// `headlineID`: a window dropping out of a reply shows a dash instead of promoting another one
/// into its place. `headlineOf` in ui/notch.html is the same rule, so the ring and the tray agree.
fn ring_window<'a>(
    provider: &str,
    windows: &'a [usage::LimitWindow],
    antigravity_limit: &str,
    antigravity_model: &str,
) -> Option<&'a usage::LimitWindow> {
    let by_id = |id: &str| windows.iter().find(|w| w.id == id);
    if pace::claude(provider) {
        if let Some(daily) = by_id(pace::DAILY_ID) {
            return Some(daily);
        }
    }
    match provider {
        "claude" => by_id("session"),
        "codex" => by_id("primary"),
        "cursor" => by_id("included").or_else(|| by_id("api")),
        "grok" => by_id("credits").or_else(|| windows.first()),
        // The Mac sets headlineID "session", weeklyID "weekly". Without this the
        // plan falls through to Antigravity's lane picker and the ring shows the
        // tightest window it can find instead of the session.
        "glm" => by_id("session"),
        "gemini" => antigravity_lane(windows, antigravity_limit, antigravity_model),
        id if id.starts_with("claude-") => by_id("session"),
        id if id.starts_with("codex-") => by_id("primary"),
        id if id.starts_with("antigravity-") => {
            antigravity_lane(windows, antigravity_limit, antigravity_model)
        }
        _ => {
            if let Some(p) = providers::CATALOG.iter().find(|p| p.id == provider) {
                by_id(p.headline)
            } else {
                windows.first()
            }
        }
    }
}

/// Antigravity's lane, chosen as the Mac app's "Notch reads" and "Model data" choose it: within the
/// model family (or every lane, if none belongs to it), the tightest lane of the chosen cadence; on
/// Automatic, the tightest lane that still has room, or the tightest of all once every one is spent.
fn antigravity_lane<'a>(
    windows: &'a [usage::LimitWindow],
    limit: &str,
    model: &str,
) -> Option<&'a usage::LimitWindow> {
    let family: Vec<_> = windows.iter().filter(|w| lane_family(w) == model).collect();
    let lanes = if family.is_empty() {
        windows.iter().collect()
    } else {
        family
    };
    if limit != "automatic" {
        if let Some(w) = tightest(lanes.iter().copied().filter(|w| lane_is(w, limit))) {
            return Some(w);
        }
    }
    tightest(lanes.iter().copied().filter(|w| w.used < 1.0))
        .or_else(|| tightest(lanes.iter().copied()))
        .or_else(|| lanes.first().copied())
}

/// "gemini" or "3p", from the language server's `gemini-5h` ids or the CLI's "Gemini Models …" ones
fn lane_family(w: &usage::LimitWindow) -> &'static str {
    let id = w.id.to_lowercase();
    if id.starts_with("gemini") {
        "gemini"
    } else if id.starts_with("3p") || id.starts_with("claude") {
        "3p"
    } else {
        ""
    }
}

/// Whether a lane is the 5-hour or the weekly one, by the words the Mac app looks for
fn lane_is(w: &usage::LimitWindow, limit: &str) -> bool {
    let text = format!("{} {}", w.id, w.label).to_lowercase();
    match limit {
        "weekly" => text.contains("weekly"),
        _ => [
            "5h",
            "5-hour",
            "five hour",
            "five-hour",
            "hourly",
            "session",
        ]
        .iter()
        .any(|k| text.contains(k)),
    }
}

/// Ids match the ones the page uses, so the tray, the settings window and the notch all agree.
pub(crate) fn snapshot_of(app: &AppHandle, id: &str) -> usage::UsageSnapshot {
    if let Some(snapshot) = smoke::swift_snapshot(id) {
        return snapshot;
    }
    if let Some((runtime, _)) = id.split_once(":model:") {
        if matches!(runtime, "ollama-local" | "lmstudio") {
            if !providers::enabled(app, id) { return usage::UsageSnapshot::default(); }
            let parent = snapshot_of(app, runtime);
            return local_runtime::all_cell_snapshots(runtime, &parent)
                .into_iter().find(|(cell_id, _)| cell_id == id)
                .map(|(_, snapshot)| snapshot).unwrap_or_default();
        }
    }
    if !providers::enabled(app, id) {
        return usage::UsageSnapshot::default();
    }
    let st = app.state::<AppState>();
    let snapshot = match id {
        "codex" => st.codex.lock().unwrap().clone(),
        "cursor" => st.cursor.lock().unwrap().clone(),
        "grok" => st.grok.lock().unwrap().clone(),
        "gemini" => st.antigravity.lock().unwrap().clone(),
        "glm" => st.glm.lock().unwrap().clone(),
        "claude" => {
            let own = providers::snapshot("claude");
            if own.status == "absent" {
                st.usage.lock().unwrap().clone()
            } else {
                own
            }
        }
        _ => custom_endpoint::readings(app)
            .into_iter()
            .find(|p| p.id == id)
            .map(|p| p.snap)
            .unwrap_or_else(|| providers::snapshot(id)),
    };
    let enabled = st.cfg.lock().unwrap().appearance.claude_daily_pace;
    pace::apply(id, snapshot, enabled, now_ms())
}

/// A provider's ring as a whole percentage, for the tray icon and the settings picker. A count
/// window has no percentage to draw, so it is a dash.
pub(crate) fn ring_fraction(app: &AppHandle, provider: &str) -> Option<f64> {
    let snap = snapshot_of(app, provider);
    if snap.status == "absent" {
        return None;
    }
    let (limit, model) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (c.antigravity_limit.clone(), c.antigravity_model.clone())
    };
    ring_window(provider, &snap.windows, &limit, &model)
        .and_then(usage::LimitWindow::fraction)
        .map(|fraction| fraction.clamp(0.0, 1.0))
}

pub(crate) fn ring_pct(app: &AppHandle, provider: &str) -> Option<u32> {
    let snap = snapshot_of(app, provider);
    if snap.status == "absent" {
        return None;
    }
    let (limit, model) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (c.antigravity_limit.clone(), c.antigravity_model.clone())
    };
    ring_window(provider, &snap.windows, &limit, &model)
        .and_then(usage::LimitWindow::fraction)
        .map(|fraction| (fraction * 100.0).round().clamp(0.0, 100.0) as u32)
}

/// One provider and its ring's current number, for the settings window's picker.
#[derive(serde::Serialize)]
struct TrayOption {
    id: String,
    label: String,
    status: String,
    used: Option<u32>,
    text: String,
}

#[tauri::command]
fn get_tray_options(app: AppHandle) -> Vec<TrayOption> {
    if let Some(rows) = smoke::swift_rows() {
        return rows
            .into_iter()
            .map(|row| {
                let used = row
                    .snap
                    .windows
                    .iter()
                    .find(|window| window.id == row.headline)
                    .and_then(usage::LimitWindow::fraction)
                    .map(|fraction| (fraction * 100.0).round().clamp(0.0, 100.0) as u32);
                let text = traymenu::headline_value(row.snap.windows.iter().find(|window| window.id == row.headline));
                TrayOption {
                    id: row.id,
                    label: row.name,
                    status: row.snap.status,
                    used,
                    text,
                }
            })
            .collect();
    }
    let extra = providers::get_providers(app.clone());
    TRAY_PROVIDER_IDS
        .iter()
        .copied()
        .chain(
            extra
                .iter()
                .filter(|p| !TRAY_PROVIDER_IDS.contains(&p.id.as_str()))
                .map(|p| p.id.as_str()),
        )
        .map(|id| TrayOption {
            id: id.to_string(),
            label: extra
                .iter()
                .find(|p| p.id == id)
                .map(|p| p.name.clone())
                .unwrap_or_else(|| provider_label(id).to_string()),
            status: snapshot_of(&app, id).status,
            used: ring_pct(&app, id),
            text: {
                let snap = snapshot_of(&app, id);
                let (limit, model) = {
                    let c = app.state::<AppState>();
                    let c = c.cfg.lock().unwrap();
                    (c.antigravity_limit.clone(), c.antigravity_model.clone())
                };
                if let Some(local) = snap.local_model.as_ref() {
                    local_runtime::memory_text(local)
                } else {
                    traymenu::headline_value(ring_window(id, &snap.windows, &limit, &model))
                }
            },
        })
        .collect()
}

/// Antigravity's "Notch reads" and "Model data", as the Mac app has them.
#[derive(serde::Serialize)]
struct AntigravityPrefs {
    limit: String,
    model: String,
}

#[tauri::command]
fn get_antigravity_prefs(app: AppHandle) -> AntigravityPrefs {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    AntigravityPrefs {
        limit: c.antigravity_limit.clone(),
        model: c.antigravity_model.clone(),
    }
}

fn refresh_changed_antigravity_accounts(
    changed: bool,
    ids: impl FnOnce() -> Vec<String>,
    mut enabled: impl FnMut(&str) -> bool,
    mut request: impl FnMut(&str),
) {
    if !changed {
        return;
    }
    for id in ids() {
        if enabled(&id) {
            request(&id);
        }
    }
}

/// Unknown values are refused rather than stored. The notch draws its own rings, so it is told.
#[tauri::command]
fn set_antigravity_prefs(app: AppHandle, limit: String, model: String) -> AntigravityPrefs {
    let (prefs, changed) = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        let previous = (c.antigravity_limit.clone(), c.antigravity_model.clone());
        if ["automatic", "5h", "weekly"].contains(&limit.as_str()) {
            c.antigravity_limit = limit;
        }
        if ["gemini", "3p"].contains(&model.as_str()) {
            c.antigravity_model = model;
        }
        config::save(&c);
        (
            AntigravityPrefs {
                limit: c.antigravity_limit.clone(),
                model: c.antigravity_model.clone(),
            },
            previous != (c.antigravity_limit.clone(), c.antigravity_model.clone()),
        )
    };
    let _ = app.emit("antigravity_prefs", &prefs);
    tray::refresh_menu(&app);
    refresh_changed_antigravity_accounts(
        changed,
        providers::antigravity_profile_ids,
        |id| providers::enabled(&app, id),
        |id| {
            let _ = refresh_provider(&app, id);
        },
    );
    prefs
}

/// None preserves legacy automatic selection; Some([]) is an intentional empty notch.
#[tauri::command]
fn get_notch_slots(app: AppHandle) -> Option<Vec<config::TraySlot>> {
    if smoke::swift_rows().is_some() {
        return Some(
            ["claude", "openai", "third"]
                .into_iter()
                .map(|provider| config::TraySlot {
                    provider: provider.into(),
                })
                .collect(),
        );
    }
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    let selected = c.notch_selection_explicit || !c.notch_slots.is_empty();
    let mut slots = c.notch_slots.clone();
    drop(c);
    if !selected { return None; }
    if slots.is_empty() { return Some(slots); }
    let mut seen: std::collections::HashSet<String> = slots.iter().map(|slot| slot.provider.clone()).collect();
    for row in get_tray_options(app.clone()) {
        if row.status != "absent" && providers::enabled(&app, &row.id) && seen.insert(row.id.clone()) {
            slots.push(config::TraySlot { provider: row.id });
        }
    }
    Some(slots)
}

/// Keep temporarily missing profile/model ids at the tail when a visible cell is reordered.
/// An explicit empty selection remains empty; removing a currently present id remains removal.
fn remember_notch_slots(
    requested: Vec<config::TraySlot>,
    previous: &[config::TraySlot],
    present: &std::collections::HashSet<String>,
) -> Vec<config::TraySlot> {
    if requested.is_empty() { return requested; }
    let mut result = requested;
    let mut seen: std::collections::HashSet<String> = result.iter().map(|slot| slot.provider.clone()).collect();
    for slot in previous {
        if !present.contains(&slot.provider) && seen.insert(slot.provider.clone()) {
            result.push(slot.clone());
        }
    }
    result
}

#[tauri::command]
fn set_notch_slots(app: AppHandle, slots: Vec<config::TraySlot>) -> Result<(), String> {
    let mut seen = std::collections::HashSet::new();
    if slots.len() > 256
        || slots
            .iter()
            .any(|s| s.provider.is_empty() || s.provider.len() > 200 || !seen.insert(&s.provider))
    {
        return Err("无效或重复的账户选择".into());
    }
    let present: std::collections::HashSet<String> = get_tray_options(app.clone())
        .into_iter().filter(|row| row.status != "absent")
        .map(|row| row.id).collect();
    let st = app.state::<AppState>();
    let mut cfg = st.cfg.lock().unwrap();
    let mut next = cfg.clone();
    let slots = remember_notch_slots(slots, &cfg.notch_slots, &present);
    if slots.len() > 256 { return Err("账户选择过多".into()); }
    next.notch_selection_explicit = true;
    next.notch_slots = slots.clone();
    next.notch_providers = slots.iter().map(|s| s.provider.clone()).collect();
    config::save_checked(&next)?;
    *cfg = next;
    drop(cfg);
    let _ = app.emit("notch_slots", slots);
    Ok(())
}

/// The application's own icon, so the settings window shows what the taskbar shows.
#[tauri::command]
fn get_app_icon() -> Option<String> {
    trayicon::app_mark_data_url()
}

/// The pinned Swift release does not offer Phone Link. The visual harness may expose its
/// isolated controls, but a production WebView cannot turn the listener on through IPC.
#[tauri::command]
fn get_phone_availability() -> bool {
    phone_link::is_available()
}

// ---------------- what is on screen at all ----------------

#[derive(serde::Serialize, Clone)]
struct UiFlags {
    notch_visible: bool,
    notch_on_hover: bool,
    tray_visible: bool,
    fullscreen: bool,
    pinned: bool,
}

fn ui_flags(c: &config::Config) -> UiFlags {
    let (fullscreen, pinned) = {
        let runtime = native_notch::runtime("notch");
        let rt = runtime.lock().unwrap();
        (rt.fullscreen, rt.pinned)
    };
    UiFlags {
        notch_visible: c.notch_visible,
        notch_on_hover: c.notch_on_hover,
        tray_visible: c.appearance.app_presence == "menuBar",
        fullscreen,
        pinned,
    }
}

#[tauri::command]
fn get_ui_flags(app: AppHandle, window: tauri::WebviewWindow) -> UiFlags {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    let mut flags = ui_flags(&c);
    if native_notch::is_notch_label(window.label()) {
        let runtime = native_notch::runtime(window.label());
        let rt = runtime.lock().unwrap();
        flags.pinned = rt.pinned;
        flags.fullscreen = rt.fullscreen;
    }
    flags
}

/// The separate App icon preference owns Dock/Taskbar vs menu bar/tray visibility. When both
/// controls are hidden, launching Velo again opens Settings via the single-instance callback.
#[tauri::command]
fn set_ui_flags(
    app: AppHandle,
    notch_visible: bool,
    tray_visible: bool,
    notch_on_hover: Option<bool>,
) -> UiFlags {
    let flags = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        if c.notch_visible != notch_visible || notch_on_hover.is_some_and(|v| v != c.notch_on_hover)
        {
            for window in app
                .webview_windows()
                .values()
                .filter(|w| native_notch::is_notch_label(w.label()))
            {
                native_notch::runtime(window.label()).lock().unwrap().pinned = false;
            }
        }
        c.notch_visible = notch_visible;
        if let Some(on_hover) = notch_on_hover {
            c.notch_on_hover = on_hover;
        }
        c.tray_visible = tray_visible;
        config::save(&c);
        ui_flags(&c)
    };
    apply_visibility(&app);
    flags
}

/// Swift's temporary pin is independent of the persistent Show setting.
pub fn toggle_keep_open(app: &AppHandle) {
    toggle_keep_open_for(app, "notch");
}
pub fn toggle_keep_open_for(app: &AppHandle, label: &str) {
    let runtime = native_notch::runtime(label);
    let mut rt = runtime.lock().unwrap();
    rt.pinned = !rt.pinned;
    let pinned = rt.pinned;
    drop(rt);
    let _ = app.emit_to(label, "notch_pinned", pinned);
}
#[tauri::command]
fn toggle_notch_pin(app: AppHandle, window: tauri::WebviewWindow) {
    if native_notch::is_notch_label(window.label()) {
        toggle_keep_open_for(&app, window.label());
    }
}

pub fn keeps_open(_app: &AppHandle) -> bool {
    keeps_open_for("notch")
}
pub fn keeps_open_for(label: &str) -> bool {
    native_notch::runtime(label).lock().unwrap().pinned
}

/// Puts the two switches into effect.
pub fn apply_visibility(app: &AppHandle) {
    let (notch, tray_on, flags) = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        (c.notch_visible, c.appearance.app_presence == "menuBar", ui_flags(&c))
    };
    // Visibility is shared; a temporary pin belongs to one panel only.
    let _ = app.emit_to("settings", "ui_flags", &flags);
    for w in app
        .webview_windows()
        .values()
        .filter(|w| native_notch::is_notch_label(w.label()))
    {
        let mut local = flags.clone();
        let runtime = native_notch::runtime(w.label());
        let (pinned, fullscreen) = {
            let rt = runtime.lock().unwrap();
            (rt.pinned, rt.fullscreen)
        };
        local.pinned = pinned;
        local.fullscreen = fullscreen;
        let _ = app.emit_to(w.label(), "ui_flags", local);
        if notch {
            let _ = w.show();
        } else {
            let _ = w.hide();
        }
    }
    if notch {
        place_notch(app);
    }
    if let Some(t) = app.tray_by_id("main") {
        let _ = t.set_visible(tray_on);
    }
    settings_window::apply_presence(app);
}

// ---------------- settings that used to live in the tray menu ----------------

#[tauri::command]
fn get_lang(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.lang.clone()
}

/// The settings WebView must use the same Windows locale as the tray. WebView2's
/// navigator.language can describe the browser runtime rather than the user locale.
#[tauri::command]
fn get_lang_resolved(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    resolved_lang(&c.lang)
}

#[tauri::command]
fn get_autostart() -> bool {
    if smoke::root().is_some() {
        return false;
    }
    autostart::is_enabled()
}

#[tauri::command]
fn get_autostart_problem() -> Option<String> {
    if smoke::root().is_some() { return None; }
    autostart::problem()
}

#[tauri::command]
fn set_autostart(on: bool) -> Result<String, String> {
    if smoke::root().is_some() {
        return Err("Start at login is unavailable in visual-test mode".into());
    }
    if on {
        autostart::enable()
    } else {
        autostart::disable()
    }
}

#[tauri::command]
fn get_hooks_installed() -> bool {
    if smoke::root().is_some() {
        return false;
    }
    hooks_install::is_installed()
}

#[tauri::command]
fn set_hooks_installed(on: bool) -> Result<String, String> {
    if on {
        hooks_install::install()
    } else {
        hooks_install::uninstall()
    }
}

#[tauri::command]
fn reset_notch_position(app: AppHandle) {
    reset_bar(&app);
}

/// How much of the notch window the taskbar covers, in the page's CSS px: top, right, bottom, left.
#[tauri::command]
fn get_notch_insets(window: tauri::WebviewWindow) -> [f64; 4] {
    native_notch::runtime(window.label()).lock().unwrap().insets
}

/// Which screen edge the notch is pinned to.
#[tauri::command]
fn get_notch_edge(app: AppHandle) -> String {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    config::edge_or_right(&c.notch_edge)
}

/// Moving to another edge puts the notch where it was last left on that edge, or centred if it has
/// never been slid along it — each edge keeps its own place, as on the Mac.
#[tauri::command]
fn set_notch_edge(app: AppHandle, edge: String) -> String {
    let value = {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_edge = config::edge_or_right(&edge);
        config::save(&c);
        c.notch_edge.clone()
    };
    place_notch(&app);
    value
}

#[tauri::command]
fn get_move_handle(app: AppHandle) -> bool {
    let st = app.state::<AppState>();
    let c = st.cfg.lock().unwrap();
    c.show_move_handle
}

#[tauri::command]
fn set_move_handle(app: AppHandle, on: bool) -> bool {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.show_move_handle = on;
        config::save(&c);
    }
    let _ = app.emit("move_handle", on);
    on
}

/// One attached monitor, as Settings lists it.
#[derive(serde::Serialize)]
pub struct MonitorInfo {
    /// The system device name (`\\.\DISPLAY2`); absent on a monitor the platform will not name,
    /// which then cannot be chosen explicitly and falls back to primary.
    pub id: Option<String>,
    /// "1  2560 × 1440" — enough to tell two identical screens apart by where they sit
    pub label: String,
    pub primary: bool,
    pub current: bool,
    pub pinned: bool,
    /// The saved pin is retained while its physical display is disconnected.
    pub unavailable: bool,
}

#[tauri::command]
fn get_monitors(app: AppHandle) -> Vec<MonitorInfo> {
    let want = {
        let st = app.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        c.notch_monitor.clone()
    };
    let list = screens(&app);
    let chosen = target_screen(&app).and_then(|s| s.stable_id.or(s.name));
    let mut rows: Vec<_> = list.iter()
        .enumerate()
        .map(|(i, s)| MonitorInfo {
            id: s.stable_id.clone().or_else(|| s.name.clone()),
            label: format!("{}  {} × {}", i + 1, s.w, s.h),
            primary: i == 0,
            current: s.stable_id.as_ref().or(s.name.as_ref()) == chosen.as_ref(),
            pinned: want.as_deref().is_some_and(|id| screen_id_matches(s, id)),
            unavailable: false,
        })
        .collect();
    if want.as_ref().is_some_and(|_| !rows.iter().any(|row| row.pinned)) {
        rows.push(MonitorInfo {
            id: want,
            label: "Unavailable display".into(),
            primary: false,
            current: false,
            pinned: true,
            unavailable: true,
        });
    }
    rows
}

/// `None` follows the frontmost window; disconnected displays fall back without stranding the notch.
#[tauri::command]
fn set_notch_monitor(app: AppHandle, id: Option<String>) {
    {
        let st = app.state::<AppState>();
        let mut c = st.cfg.lock().unwrap();
        c.notch_monitor = id.filter(|s| !s.is_empty());
        config::save(&c);
    }
    place_notch(&app);
}

#[tauri::command]
fn open_settings(app: AppHandle) {
    settings_window::open(&app);
}

#[tauri::command]
fn toggle_settings(app: AppHandle) {
    settings_window::toggle(&app);
}

/// Epoch milliseconds. Every polling module keeps its own copy of this; the tray menu's wording
/// needs one that is not private to a poller.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn provider_label(id: &str) -> &'static str {
    match id {
        "codex" => "Codex",
        "cursor" => "Cursor",
        "grok" => "Grok",
        "gemini" => "Antigravity",
        "glm" => "z.ai",
        _ => "Claude",
    }
}

/// Every provider the tray menu can offer, in the order the notch shows them.
pub const TRAY_PROVIDER_IDS: [&str; 6] = ["claude", "codex", "glm", "cursor", "grok", "gemini"];

/// Keeps the tray menu current. macOS rebuilds its menu as it opens; Tauri has no such hook, so it
/// is rebuilt whenever a reading changes, and once a minute besides — otherwise "Resets in 12 min"
/// sits there being wrong while nothing else happens.
fn start_menu_updater(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last: Option<Vec<Option<i64>>> = None;
        let mut ticked = std::time::Instant::now();
        loop {
            std::thread::sleep(std::time::Duration::from_secs(2));
            let values: Vec<Option<i64>> = TRAY_PROVIDER_IDS
                .iter()
                .map(|id| ring_fraction(&app, id).map(|f| (f * 1000.0).round() as i64))
                .collect();
            let changed = last.as_ref() != Some(&values);
            if !changed && ticked.elapsed() < std::time::Duration::from_secs(60) {
                tray::refresh_summary(&app);
                continue;
            }
            if changed {
                last = Some(values);
            }
            ticked = std::time::Instant::now();
            tray::refresh_menu(&app);
        }
    });
}

/// Seen-clears-it: looking at a session acknowledges it (engine behaviour, unchanged)
#[cfg(any(windows, target_os = "macos"))]
fn ack_scan(app: &AppHandle) -> bool {
    let need = {
        let st = app.state::<AppState>();
        let store = st.store.lock().unwrap();
        store.has_done()
    };
    if !need {
        return false;
    }
    let fg = focus::fg_pid();
    if fg == 0 {
        return false;
    }
    let maps = focus::proc_maps();
    let fg_name = maps.name.get(&fg).cloned().unwrap_or_default();
    let fg_is_claude_desktop = fg_name.contains("claude") && !fg_name.contains("vela");
    let st = app.state::<AppState>();
    let mut store = st.store.lock().unwrap();
    store.ack_done(|s| {
        if s.ppid == 0 {
            fg_is_claude_desktop
        } else {
            focus::pid_hits_chain(fg, &focus::chain_of(s.ppid, &maps.ppid), &maps)
        }
    })
}
#[cfg(not(any(windows, target_os = "macos")))]
fn ack_scan(_app: &AppHandle) -> bool {
    false
}

// ---------------- main ----------------

#[cfg(windows)]
fn attach_console() {
    use windows::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};
    unsafe {
        let _ = AttachConsole(ATTACH_PARENT_PROCESS);
    }
}
#[cfg(not(windows))]
fn attach_console() {}

fn report(r: Result<String, String>) {
    let msg = match r {
        Ok(m) => format!("OK: {m}"),
        Err(e) => format!("FAILED: {e}"),
    };
    println!("{msg}");
    let log = config::config_path().with_file_name("install.log");
    let _ = std::fs::write(log, &msg);
}

/// The subcommands that print to the parent console; only those may attach to it.
const CONSOLE_CMDS: [&str; 4] = ["install-hooks", "uninstall-hooks", "autostart", "doctor"];

fn finish_setup(handle: AppHandle, port: u16, first_launch: bool) -> tauri::Result<()> {
    place_notch(&handle);
    if let Some(w) = handle.get_webview_window("notch") {
        notch_window::configure(&w);
        let _ = w.show();
    }
    native_notch::apply_preferences(&handle);
    tray::setup(&handle)?;
    settings_window::install_app_menu(&handle)?;
    settings_window::apply_presence(&handle);
    notchmenu::setup(&handle);
    if smoke::root().is_some() {
        if !smoke::visual() {
            #[cfg(target_os = "macos")]
            smoke::record_wake_subscription(native_lifecycle::probe_wake_subscription());
            #[cfg(windows)]
            smoke::record_wake_subscription(windows_lifecycle::probe_wake_subscription());
        }
        if smoke::visual() {
            smoke::seed_visual(&handle);
            reload_glyphs(&handle);
            start_pointer_watchdog(handle.clone(), "notch".into());
        }
        smoke::start(&handle);
        return Ok(());
    }
    start_menu_updater(handle.clone());
    local_runtime::reconcile(&handle);
    #[cfg(target_os = "macos")]
    settings_window::start_system_look_watch(handle.clone());
    updater::check_on_launch(&handle);

    // Honours the saved switches: a notch hidden last time stays hidden.
    apply_visibility(&handle);
    server::start(handle.clone(), port);
    watcher::start(handle.clone());
    usage::start(handle.clone());
    codex::start(handle.clone());
    cursor::start(handle.clone());
    grok::start(handle.clone());
    antigravity::start(handle.clone());
    glm::start(handle.clone());
    notifications::start(handle.clone());
    phone_link::start(handle.clone());
    providers::start(handle.clone());
    activity::start(handle.clone());
    #[cfg(target_os = "macos")]
    native_lifecycle::start_wake_watch(handle.clone());
    #[cfg(windows)]
    windows_lifecycle::start_wake_watch(handle.clone());
    // Collecting glyphs may read icon resources out of a few executables; do it off the main thread and push when done
    let gh = handle.clone();
    std::thread::spawn(move || reload_glyphs(&gh));
    start_pointer_watchdog(handle.clone(), "notch".into());
    start_work_area_watch(handle.clone());
    // Seen-clears-it scan
    let acker = handle.clone();
    std::thread::spawn(move || {
        activity::lower_thread_priority();
        loop {
            std::thread::sleep(std::time::Duration::from_millis(1500));
            if ack_scan(&acker) {
                broadcast(&acker);
            }
        }
    });
    // Stale session cleanup
    let sweeper = handle.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(std::time::Duration::from_secs(30));
        let changed = {
            let st = sweeper.state::<AppState>();
            let mut s = st.store.lock().unwrap();
            s.sweep()
        };
        if changed {
            broadcast(&sweeper);
        }
    });
    // Persist the config (vela-hook reads the port from it)
    {
        let st = handle.state::<AppState>();
        let c = st.cfg.lock().unwrap();
        config::save(&c);
    }
    whats_new::show_if_needed(&handle, first_launch);
    Ok(())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(error) = smoke::configure(&args) {
        eprintln!("{error}");
        std::process::exit(1);
    }
    if let Some(cmd) = args.get(1) {
        // Attaching on the GUI path too tied the notch to whatever cmd.exe launched it: closing that
        // window sends CTRL_CLOSE_EVENT to every process on the console, and with no handler the
        // default action ends the process. The exe is already windows_subsystem = "windows", so the
        // GUI run wants no console at all.
        if CONSOLE_CMDS.contains(&cmd.as_str()) {
            attach_console();
        }
        match cmd.as_str() {
            "install-hooks" => {
                report(hooks_install::install());
                return;
            }
            "uninstall-hooks" => {
                report(hooks_install::uninstall());
                return;
            }
            "autostart" => {
                let r = match args.get(2).map(|s| s.as_str()) {
                    Some("on") => autostart::enable(),
                    Some("off") => autostart::disable(),
                    _ => Err("usage: velo.exe autostart on|off".into()),
                };
                report(r);
                return;
            }
            "doctor" => {
                let out = if args.get(2).map(|s| s.as_str()) == Some("deep") {
                    diag::run()
                } else {
                    doctor::run()
                };
                println!("{out}");
                let log = config::config_path().with_file_name("doctor.log");
                let _ = std::fs::write(log, &out);
                return;
            }
            _ => {}
        }
    }

    // AppDelegate's newcomer-wins rule runs before reading preferences or creating a notch.
    // An isolated smoke/visual/update verifier must never touch an installed Velo instance.
    #[cfg(target_os = "macos")]
    if smoke::root().is_none() {
        native_lifecycle::retire_older_instances();
    }

    let first_launch = smoke::root().is_none() && !config::config_path().exists();
    let mut cfg = if smoke::root().is_some() {
        config::Config::default()
    } else {
        config::load()
    };
    if smoke::root().is_none() && providers::reconcile_connections(&mut cfg, !first_launch) {
        if let Err(error) = config::save_checked(&cfg) {
            applog(&format!("provider connection migration: {error}"));
        }
    }
    let port = cfg.port;
    // A disabled provider must not flash its last persisted quota before the first refresh.
    // Keep this decision tied to the already-loaded configuration; no credential or config reread.
    let disabled_at_launch = cfg.providers.disabled.clone();

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_updater::Builder::new().build());
    // Isolated verification must never activate or send commands to an installed instance.
    #[cfg(not(target_os = "macos"))]
    let builder = if smoke::root().is_none() {
        builder.plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // Opening Velo again while it runs brings Settings forward, as on the Mac: with the
            // tray icon hidden it is the way back. Logged too, for a rebuild that was not picked up.
            applog(&format!("single instance: another launch was refused; the running instance is build={BUILD} — quit it from the tray first if you just rebuilt"));
            settings_window::open(app);
        }))
    } else {
        builder
    };
    builder
        .manage(AppState {
            store: Mutex::new(Default::default()),
            cfg: Mutex::new(cfg),
            usage: Mutex::new(
                if smoke::root().is_some() || disabled_at_launch.contains("claude") {
                    Default::default()
                } else {
                    usage::load_persisted()
                },
            ),
            codex: Mutex::new(
                if smoke::root().is_some() || disabled_at_launch.contains("codex") {
                    Default::default()
                } else {
                    codex::load_persisted()
                },
            ),
            cursor: Mutex::new(
                if smoke::root().is_some() || disabled_at_launch.contains("cursor") {
                    Default::default()
                } else {
                    cursor::load_persisted()
                },
            ),
            grok: Mutex::new(
                if smoke::root().is_some() || disabled_at_launch.contains("grok") {
                    Default::default()
                } else {
                    grok::load_persisted()
                },
            ),
            antigravity: Mutex::new(
                if smoke::root().is_some() || disabled_at_launch.contains("antigravity") {
                    Default::default()
                } else {
                    antigravity::load_persisted()
                },
            ),
            glm: Mutex::new(
                if smoke::root().is_some() || disabled_at_launch.contains("glm") {
                    Default::default()
                } else {
                    glm::load_persisted()
                },
            ),
            glyphs: Mutex::new(Default::default()),
            activity: Mutex::new(Vec::new()),
        })
        .invoke_handler(tauri::generate_handler![
            smoke::smoke_ready,
            custom_endpoint::get_custom_endpoints,
            custom_endpoint::get_custom_endpoint_key,
            custom_endpoint::save_custom_endpoint,
            custom_endpoint::delete_custom_endpoint,
            custom_endpoint::probe_custom_endpoint,
            custom_endpoint::save_custom_icon,
            custom_endpoint::get_custom_icon,
            custom_endpoint::discard_custom_icon,
            custom_endpoint::test_custom_endpoint_draft,
            custom_endpoint::scan_local_engines,
            local_runtime::get_local_runtime_settings,
            local_runtime::get_local_runtime_activity,
            local_runtime::get_local_models,
            local_runtime::set_local_runtime_settings,
            providers::get_providers,
            providers::get_provider_settings,
            providers::set_provider_settings,
            providers::set_provider_enabled,
            providers::get_disabled_providers,
            secrets::save_provider_secret,
            secrets::get_lmstudio_token_state,
            workbench::open_workbench,
            edge_plugins::list_edge_plugins,
            edge_plugins::set_edge_plugin,
            edge_plugins::edge_plugin_action,
            ledger::read_ledger,
            ledger::save_billing,
            ledger::get_billing,
            cli_sync::get_library,
            cli_sync::save_library,
            cli_sync::preview_sync,
            cli_sync::apply_sync,
            get_state,
            get_usage,
            claude_sign_in,
            usage::allow_claude_keychain_access,
            antigravity::allow_antigravity_keychain_access,
            account_destination::get_account_destination,
            account_destination::open_account_destination,
            get_claude_auth,
            updater::get_update_state,
            updater::check_for_update,
            updater::set_automatic_updates,
            updater::install_update,
            chime::get_alert_sounds,
            phone_link::get_phone_link,
            get_phone_availability,
            phone_link::phone_pairing,
            phone_link::set_phone_link,
            phone_link::remove_phone,
            chime::preview_alert_sound,
            notifications::preview_notch_alert,
            appearance::get_appearance,
            appearance::get_deepseek_pricing_state,
            appearance::set_appearance,
            tray::get_menu_bar_choices,
            native_notch::get_native_notch_geometry,
            native_notch::get_surface_capability,
            native_notch::report_native_surface,
            web_session::get_web_session_state,
            web_session::open_web_session,
            web_session::sign_out_web_session,
            notifications::get_notifications,
            notifications::set_notifications,
            get_codex,
            get_cursor,
            get_grok,
            get_antigravity,
            get_glm,
            get_glyphs,
            get_activity,
            open_data_dir,
            drag_begin,
            refresh_ring,
            notchmenu::show_notch_menu,
            toggle_notch_pin,
            set_hot,
            report_dpr,
            set_notch_content,
            notch_hidden,
            notch_edge_fade,
            notch_edge_visible,
            log_js,
            focus_session,
            dismiss_session,
            set_lang,
            get_scale,
            set_scale,
            get_weekly_ring,
            set_weekly_ring,
            get_tray_options,
            get_notch_slots,
            set_notch_slots,
            get_antigravity_prefs,
            set_antigravity_prefs,
            get_app_icon,
            get_ui_flags,
            set_ui_flags,
            get_lang,
            get_lang_resolved,
            get_autostart,
            get_autostart_problem,
            set_autostart,
            get_hooks_installed,
            set_hooks_installed,
            reset_notch_position,
            get_notch_edge,
            get_notch_insets,
            set_notch_edge,
            get_monitors,
            set_notch_monitor,
            open_settings,
            toggle_settings,
            begin_move,
            get_move_handle,
            set_move_handle,
            dropzones::get_zones,
            settings_window::get_system_look,
            whats_new::get_whats_new_info,
            settings_window::quit_app,
            settings_window::open_author_page
        ])
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let handle = app.handle().clone();
            if smoke::update_verification() {
                if !smoke::update_marker() {
                    updater::start_update_verification(&handle);
                    return Ok(());
                }
                if smoke::update_expected() == Some(env!("CARGO_PKG_VERSION")) {
                    finish_setup(handle, port, first_launch)?;
                    return Ok(());
                }
                if updater::apply_staged_on_launch(&handle, port, first_launch) {
                    return Ok(());
                }
                smoke::update_report(&handle, false, "handoff", "Staged installer was not accepted");
                return Ok(());
            }
            if smoke::root().is_none() && updater::apply_staged_on_launch(&handle, port, first_launch) {
                return Ok(());
            }
            finish_setup(handle, port, first_launch)?;
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Velo failed to start")
        .run(|_app, _event| {
            #[cfg(target_os = "macos")]
            match _event {
                tauri::RunEvent::Reopen { .. } => settings_window::open(_app),
                tauri::RunEvent::Exit => native_lifecycle::stop_wake_watch(),
                _ => {}
            }
            #[cfg(windows)]
            if matches!(_event, tauri::RunEvent::Exit) {
                windows_lifecycle::stop_wake_watch();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::{
        content_edge_origin, cursor_in_hot, handle_extents, notch_window_size, provider_page,
        remember_notch_slots, ring_window, visible_along_origin, work_insets, Screen, HOT_PAD,
        NOTCH_W, TRAY_PROVIDER_IDS,
    };
    use crate::usage::LimitWindow;

    #[test]
    fn explicit_simplified_chinese_alias_reaches_native_translations() {
        assert_eq!(super::resolved_lang("zh-Hans"), "zh");
        assert_eq!(super::resolved_lang("zh-Hant"), "zh-Hant");
    }

    #[test]
    fn changed_antigravity_setting_refreshes_only_connected_family_accounts() {
        let ids = || {
            vec![
                "gemini".to_string(),
                "codex".to_string(),
                "antigravity-work".to_string(),
            ]
        };
        let mut requested = Vec::new();
        super::refresh_changed_antigravity_accounts(
            false,
            || panic!("unchanged selection must not discover accounts"),
            |_| true,
            |id| requested.push(id.to_string()),
        );
        assert!(requested.is_empty(), "unchanged selection spends no requests");
        super::refresh_changed_antigravity_accounts(
            true,
            || ids().into_iter().filter(|id| id.as_str() != "codex").collect(),
            |id| id != "antigravity-work",
            |id| requested.push(id.to_string()),
        );
        assert_eq!(
            requested,
            vec!["gemini".to_string()],
            "only enabled Antigravity accounts are requested"
        );
    }

    #[test]
    fn reorder_keeps_absent_model_and_profile_ids_but_explicit_empty_wins() {
        let slot = |id: &str| crate::config::TraySlot { provider: id.into() };
        let previous = [slot("claude"), slot("ollama-local:model:qwen"), slot("claude-work")];
        let present = std::collections::HashSet::from(["claude".into(), "codex".into()]);
        let next = remember_notch_slots(vec![slot("codex"), slot("claude")], &previous, &present);
        assert_eq!(next, vec![slot("codex"), slot("claude"), slot("ollama-local:model:qwen"), slot("claude-work")]);
        assert!(remember_notch_slots(Vec::new(), &previous, &present).is_empty());
    }

    /// A provider added without a page of its own used to fall through to Claude's
    #[test]
    fn every_provider_opens_its_own_page() {
        let mut hosts: Vec<&str> = TRAY_PROVIDER_IDS
            .iter()
            .map(|id| {
                provider_page(id)
                    .unwrap_or_else(|| panic!("{id} has no usage page"))
                    .1
            })
            .collect();
        hosts.sort();
        hosts.dedup();
        assert_eq!(hosts.len(), TRAY_PROVIDER_IDS.len());
        assert_eq!(provider_page("nobody"), None);
    }

    #[test]
    fn the_taskbar_is_measured_against_the_window() {
        // 3200 × 2000 with a 72 px taskbar along the bottom
        let s = Screen {
            name: None,
            stable_id: None,
            x: 0,
            y: 0,
            w: 3200,
            h: 2000,
            scale: 1.5,
            work: (0, 0, 3200, 1928),
        };
        assert_eq!(
            work_insets(&s, 2768, 1376, 432, 624),
            [0, 0, 72, 0],
            "right edge, at the bottom"
        );
        assert_eq!(
            work_insets(&s, 2768, 512, 432, 624),
            [0, 0, 0, 0],
            "right edge, clear of it"
        );
        assert_eq!(
            work_insets(&s, 1000, 1928, 624, 624).map(|v| v <= 624),
            [true; 4],
            "never more than the window"
        );
        // A taskbar on the left
        let s = Screen {
            work: (72, 0, 3128, 2000),
            ..s
        };
        assert_eq!(work_insets(&s, 0, 700, 432, 624), [0, 0, 0, 72]);
    }

    /// A slide along the edge saves `along_at` and the next placement reads it back through
    /// `edge_origin`, so the two must be exact inverses or the notch jumps when it is let go.
    #[test]
    fn a_slid_notch_lands_where_it_was_let_go() {
        let s = Screen {
            name: None,
            stable_id: None,
            x: 0,
            y: 0,
            w: 3200,
            h: 2000,
            scale: 1.5,
            work: (0, 0, 3200, 1928),
        };
        for along in [0.2, 0.5, 0.73] {
            let (_, y) = super::edge_origin(&s, "right", 432, 624, along);
            assert!(
                (super::along_at(y, 624, 0, 2000) - along).abs() < 1e-3,
                "right at {along}"
            );
            let (x, _) = super::edge_origin(&s, "top", 624, 624, along);
            assert!(
                (super::along_at(x, 624, 0, 3200) - along).abs() < 1e-3,
                "top at {along}"
            );
        }
        // Pushed hard against an end, what it saves is the end it stopped at, not the pointer
        let (_, y) = super::edge_origin(&s, "right", 432, 624, 0.0);
        assert_eq!(
            super::edge_origin(&s, "right", 432, 624, super::along_at(y, 624, 0, 2000)).1,
            y
        );
    }

    #[test]
    fn a_tall_panel_can_slide_its_visible_shape_to_both_screen_ends() {
        let s = Screen {
            name: None, stable_id: None, x: 100, y: 200, w: 1440, h: 900,
            scale: 1.0, work: (100, 200, 1440, 900),
        };
        let (ww, wh, shape) = (360, 954, 460.0);
        let extents = (29.0, 29.0);
        for edge in ["left", "right"] {
            let (top_x, top_y) = content_edge_origin(&s, edge, ww, wh, 0.0, Some(shape), extents);
            let (bottom_x, bottom_y) = content_edge_origin(&s, edge, ww, wh, 1.0, Some(shape), extents);
            assert_eq!(top_y, -18, "{edge} can put the visible move handle at the top");
            assert_eq!(bottom_y, 364, "{edge} can put the settings handle at the bottom");
            assert_eq!(top_x, bottom_x);
            for y in [top_y, 200, bottom_y] {
                let ratio = super::along_at(y, wh, s.y, s.h);
                assert_eq!(content_edge_origin(&s, edge, ww, wh, ratio, Some(shape), extents).1, y);
            }
        }
        let (hidden_x, _) = content_edge_origin(&s, "right", ww, wh, 0.0, Some(shape), (0.0, 29.0));
        assert_eq!(hidden_x, 100 + 1440 - ww);
        assert_eq!(content_edge_origin(&s, "right", ww, wh, 0.0, Some(shape), (0.0, 29.0)).1, -47);
        assert_eq!(visible_along_origin(-999.0, 200, 900, wh, Some(shape), 29.0, 29.0, true), -18);
    }

    #[test]
    fn oversized_shape_clamps_in_the_swift_coordinate_direction() {
        // Physical bounds cross: lo=-180, hi=-320. Swift's AppKit lower bound
        // maps to physical hi vertically, but remains lo horizontally.
        assert_eq!(visible_along_origin(0.0, 0, 100, 600, Some(200.0), 20.0, 20.0, true), -320);
        assert_eq!(visible_along_origin(0.0, 0, 100, 600, Some(200.0), 20.0, 20.0, false), -180);
    }

    #[test]
    fn four_edges_share_visible_bounds_and_preserve_the_physical_bezel() {
        let s = Screen {
            name: None, stable_id: None, x: 50, y: 70, w: 1440, h: 900,
            scale: 1.0, work: (50, 70, 1440, 900),
        };
        for edge in ["top", "bottom"] {
            let a = content_edge_origin(&s, edge, 954, 360, 0.0, Some(460.0), (29.0, 29.0));
            let b = content_edge_origin(&s, edge, 954, 360, 1.0, Some(460.0), (29.0, 29.0));
            assert_eq!(a.0, -168);
            assert_eq!(b.0, 754);
            assert_eq!(a.1, if edge == "top" { 70 } else { 610 });
            assert_eq!(b.1, a.1);
            for x in [a.0, 50, b.0] {
                let ratio = super::along_at(x, 954, s.x, s.w);
                assert_eq!(content_edge_origin(&s, edge, 954, 360, ratio, Some(460.0), (29.0, 29.0)).0, x);
            }
        }
        assert_eq!(handle_extents("left", 1.0, 1.0, false, None).0, 0.0);
        assert_eq!(handle_extents("right", 1.0, 1.0, true, None), (29.0, 29.0));
        let joined = super::native_notch::HardwareNotch { width: 220.0, height: 37.0 };
        assert!(handle_extents("top", 1.0, 1.0, true, Some(joined)).1 > 29.0);
    }

    #[test]
    fn dock_and_taskbar_do_not_move_the_physical_edge() {
        let s = Screen {
            name: None,
            stable_id: None,
            x: 0,
            y: 0,
            w: 3200,
            h: 2000,
            scale: 1.5,
            work: (72, 0, 3128, 1928),
        };
        assert_eq!(super::edge_origin(&s, "left", 432, 624, 0.5).0, 0);
        assert_eq!(super::edge_origin(&s, "right", 432, 624, 0.5).0, 3200 - 432);
        assert_eq!(
            super::edge_origin(&s, "bottom", 624, 624, 0.5).1,
            2000 - 624
        );
        let (x, y) = super::edge_origin(&s, "left", 432, 624, 0.5);
        assert_eq!(work_insets(&s, x, y, 432, 624), [0, 0, 0, 72]);
    }

    /// `fitZoom` treats a window wider than the page's design width as a DPI disagreement and zooms
    /// the layout to close the gap, so a design width left behind when the window is widened zooms
    /// the whole notch instead — and `placeCard`, which writes unzoomed styles from zoomed rects,
    /// then puts the card at the wrong place entirely.
    #[test]
    fn the_pages_design_widths_are_the_window_widths() {
        let page = include_str!("../ui/notch.html");
        let line = page
            .lines()
            .find(|l| l.trim_start().starts_with("const DESIGN_W_UPRIGHT"))
            .expect("notch.html declares its design widths on one line");
        let width_of = |key: &str| -> f64 {
            let after = line
                .split(key)
                .nth(1)
                .unwrap_or_else(|| panic!("{key} missing"));
            after
                .trim_start_matches('=')
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '.')
                .collect::<String>()
                .parse()
                .unwrap_or_else(|_| panic!("{key} is not a number"))
        };
        assert_eq!(width_of("DESIGN_W_UPRIGHT"), notch_window_size("right").0);
        assert_eq!(width_of("DESIGN_W_FLAT"), notch_window_size("top").0);
    }

    /// Four triangles about the centre, so every point on the screen belongs to exactly one edge.
    #[test]
    fn a_carried_notch_lands_on_the_nearest_edge() {
        let (w, h) = (2560.0, 1440.0);
        assert_eq!(super::edge_at(2500.0, 700.0, w, h), "right");
        assert_eq!(super::edge_at(20.0, 700.0, w, h), "left");
        assert_eq!(super::edge_at(1280.0, 30.0, w, h), "top");
        assert_eq!(super::edge_at(1280.0, 1400.0, w, h), "bottom");
        // The corner diagonals are the boundaries: a step either side of one changes the answer
        assert_eq!(super::edge_at(690.0, 700.0, w, h), "left");
        assert_eq!(super::edge_at(700.0, 690.0, w, h), "top");
        // A pointer off the screen — in the gap a smaller one leaves — still answers the nearest edge
        assert_eq!(super::edge_at(-200.0, 700.0, w, h), "left");
    }

    /// DropZoneOverlay remains attached to the screen where the handle was pressed.
    /// Its edge calculation keeps using that screen's coordinates after the pointer leaves it.
    #[test]
    fn a_carry_uses_the_press_screen_and_never_rewrites_monitor_preference() {
        let screen = Screen {
            name: Some("1".into()),
            stable_id: None,
            x: 0,
            y: 0,
            w: 2560,
            h: 1600,
            scale: 1.25,
            work: (0, 0, 2560, 1552),
        };
        let (x, y, w, h) = screen.area();
        assert_eq!(super::edge_at(3000.0 - x as f64, 700.0 - y as f64, w as f64, h as f64), "right");
        assert_eq!(super::edge_at(1000.0 - x as f64, -100.0 - y as f64, w as f64, h as f64), "top");
        let mut config = crate::config::Config::default();
        config.notch_edge = "right".into();
        config.notch_monitor = Some("chosen-display".into());
        assert!(!super::apply_move_edge(&mut config, "right"));
        assert_eq!(config.notch_monitor.as_deref(), Some("chosen-display"));
        assert!(super::apply_move_edge(&mut config, "top"));
        assert_eq!(config.notch_edge, "top");
        assert_eq!(config.notch_monitor.as_deref(), Some("chosen-display"));
    }

    /// Real values from the run.log in #106: a 2560×1600 display at 150 %.
    const PILL: [f64; 4] = [405.0, 183.5, 105.0, 323.0];
    const CARD: [f64; 4] = [21.0, 142.5, 369.0, 262.0];
    const WINDOW: Option<(f64, f64)> = Some((510.0, 690.0));

    #[test]
    fn nothing_is_hot_before_the_page_reports() {
        assert!(!cursor_in_hot(&[], 450.0, 300.0, WINDOW));
    }

    #[test]
    fn the_pill_is_hot() {
        assert!(cursor_in_hot(&[PILL], 450.0, 300.0, WINDOW));
    }

    #[test]
    fn the_transparent_area_beside_the_pill_is_not() {
        assert!(!cursor_in_hot(&[PILL], 0.0, 297.0, WINDOW));
        assert!(!cursor_in_hot(&[PILL], 100.0, 400.0, WINDOW));
    }

    #[test]
    fn the_card_is_hot_while_it_is_open() {
        assert!(!cursor_in_hot(&[PILL], 100.0, 250.0, WINDOW));
        assert!(cursor_in_hot(&[PILL, CARD], 100.0, 250.0, WINDOW));
    }

    #[test]
    fn the_tail_leaves_no_cold_strip_between_the_pill_and_the_card() {
        // The shipped layout at 150 %, from the CSS: the card stops 100 px from the edge and the
        // tail spans the rest, its tip under the pill's edge. A pointer crossing along the tail is
        // hot on one rectangle alone at every step, so it never leans on the bounding box.
        const WIDE: Option<(f64, f64)> = Some((540.0, 690.0));
        const WIDE_PILL: [f64; 4] = [435.0, 183.5, 105.0, 323.0];
        const TAIL: [f64; 4] = [388.5, 318.0, 48.0, 54.0];
        let y = TAIL[1] + TAIL[3] / 2.0;
        for x in (CARD[0] + CARD[2]) as i32..WIDE_PILL[0] as i32 {
            let x = x as f64;
            assert!(
                [WIDE_PILL, TAIL, CARD]
                    .iter()
                    .any(|r| cursor_in_hot(&[*r], x, y, WIDE)),
                "cold at x={x}"
            );
        }
    }

    /// The page reports the card-to-pill bridge separately. A bounding box of
    /// every hot rect would also steal clicks in the transparent corners.
    const FAR_A: [f64; 4] = [0.0, 0.0, 50.0, 50.0];
    const FAR_B: [f64; 4] = [200.0, 0.0, 50.0, 50.0];

    #[test]
    fn a_wide_gap_needs_the_explicit_card_bridge() {
        assert!(!cursor_in_hot(&[FAR_A, FAR_B], 125.0, 25.0, None));
        assert!(cursor_in_hot(&[FAR_A, FAR_B, [50.0, 0.0, 150.0, 50.0]], 125.0, 25.0, None));
    }

    #[test]
    fn a_card_does_not_make_the_far_transparent_corner_hot() {
        let pill = [400.0, 200.0, 100.0, 300.0];
        let card = [0.0, 300.0, 200.0, 100.0];
        let bridge = [200.0, 300.0, 200.0, 100.0];
        let handle = [430.0, 140.0, 57.0, 57.0];
        assert!(cursor_in_hot(&[pill, card, bridge, handle], 300.0, 350.0, None));
        assert!(!cursor_in_hot(&[pill, card, bridge, handle], 80.0, 180.0, None));
    }

    #[test]
    fn the_pad_reaches_slightly_past_the_pill() {
        assert!(cursor_in_hot(
            &[PILL],
            PILL[0] - HOT_PAD + 1.0,
            300.0,
            WINDOW
        ));
        assert!(!cursor_in_hot(
            &[PILL],
            PILL[0] - HOT_PAD - 1.0,
            300.0,
            WINDOW
        ));
    }

    #[test]
    fn a_cursor_off_the_window_is_never_hot() {
        assert!(!cursor_in_hot(&[PILL], 515.0, 300.0, WINDOW));
        assert!(!cursor_in_hot(&[PILL], 450.0, -5.0, WINDOW));
    }

    #[test]
    fn an_unreadable_window_size_falls_back_to_the_rectangles() {
        assert!(cursor_in_hot(&[PILL], 450.0, 300.0, None));
        assert!(!cursor_in_hot(&[PILL], 100.0, 300.0, None));
    }

    fn win(id: &str, used: f64) -> LimitWindow {
        LimitWindow {
            id: id.into(),
            used,
            ..Default::default()
        }
    }

    fn pick<'a>(provider: &str, windows: &'a [LimitWindow]) -> Option<&'a str> {
        ring_window(provider, windows, "automatic", "gemini").map(|w| w.id.as_str())
    }

    fn lane<'a>(windows: &'a [LimitWindow], limit: &str, model: &str) -> Option<&'a str> {
        ring_window("gemini", windows, limit, model).map(|w| w.id.as_str())
    }

    /// The four lanes Antigravity's language server reported on a real machine
    fn bridge() -> [LimitWindow; 4] {
        [
            win("gemini-weekly", 0.03),
            win("gemini-5h", 0.0),
            win("3p-weekly", 0.5),
            win("3p-5h", 0.9),
        ]
    }

    #[test]
    fn claude_means_the_session_even_when_the_week_is_fuller() {
        assert_eq!(
            pick("claude", &[win("session", 0.10), win("weekly_all", 0.60)]),
            Some("session")
        );
    }

    #[test]
    fn a_missing_declared_window_is_a_dash_not_a_stand_in() {
        assert_eq!(pick("claude", &[win("weekly_all", 0.60)]), None);
    }

    #[test]
    fn codex_means_its_core_window_and_cursor_its_included_usage() {
        assert_eq!(
            pick("codex", &[win("primary", 0.2), win("secondary", 0.9)]),
            Some("primary")
        );
        assert_eq!(
            pick("cursor", &[win("included", 0.3), win("api", 0.9)]),
            Some("included")
        );
        assert_eq!(
            pick("cursor", &[win("api", 0.9), win("on_demand", 0.95)]),
            Some("api")
        );
    }

    #[test]
    fn codex_never_substitutes_an_extra_bucket_for_core_usage() {
        assert_eq!(
            pick("codex", &[win("spark", 0.1), win("primary", 0.32)]),
            Some("primary")
        );
        assert_eq!(
            pick("codex", &[win("spark", 0.1), win("secondary", 0.4)]),
            None
        );
        assert_eq!(pick("codex", &[win("secondary", 0.4)]), None);
        assert_eq!(
            pick("codex", &[win("spark", 0.1), win("code-review", 0.2)]),
            None
        );
    }

    #[test]
    fn antigravity_reads_only_gemini_lanes_unless_told_otherwise() {
        assert_eq!(
            lane(&bridge(), "automatic", "gemini"),
            Some("gemini-weekly")
        );
        assert_eq!(lane(&bridge(), "automatic", "3p"), Some("3p-5h"));
    }

    #[test]
    fn notch_reads_picks_the_five_hour_or_the_weekly_lane() {
        assert_eq!(lane(&bridge(), "5h", "gemini"), Some("gemini-5h"));
        assert_eq!(lane(&bridge(), "weekly", "3p"), Some("3p-weekly"));
    }

    #[test]
    fn the_cli_names_its_lanes_differently_and_still_matches() {
        let cli = [
            win("Gemini Models Weekly Limit", 0.2),
            win("Gemini Models Five Hour Limit", 0.1),
            win("Claude and GPT models Five Hour Limit", 0.7),
        ];
        assert_eq!(
            lane(&cli, "5h", "gemini"),
            Some("Gemini Models Five Hour Limit")
        );
        assert_eq!(
            lane(&cli, "automatic", "3p"),
            Some("Claude and GPT models Five Hour Limit")
        );
    }

    #[test]
    fn a_spent_lane_leads_only_once_every_lane_is_spent() {
        let one_spent = [win("gemini-5h", 1.0), win("gemini-weekly", 0.4)];
        assert_eq!(
            lane(&one_spent, "automatic", "gemini"),
            Some("gemini-weekly")
        );
        let all_spent = [win("gemini-weekly", 1.0), win("gemini-5h", 1.0)];
        assert_eq!(lane(&all_spent, "automatic", "gemini"), Some("gemini-5h"));
    }

    #[test]
    fn a_request_count_still_leads_when_it_is_all_there_is() {
        let requests = LimitWindow {
            id: "requests".into(),
            count: Some(79),
            ..Default::default()
        };
        assert_eq!(
            pick("gemini", std::slice::from_ref(&requests)),
            Some("requests")
        );
    }
}
