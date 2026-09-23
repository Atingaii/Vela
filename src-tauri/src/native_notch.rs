//! AppKit display facts for the notch. Read on the main thread after the window is placed;
//! a Tauri monitor's name and work area cannot describe the MacBook camera housing.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use tauri::{AppHandle, Emitter, Manager};

/// A separate WebView has separate layout, hover, zoom and landing state even when all panels
/// share the same snapshots and preferences. Keeping these keyed by label prevents a secondary
/// display from changing the primary panel's hit test or card fit.
#[derive(Default)]
pub struct WindowRuntime {
    pub edge_transition: crate::edge_transition::Transition,
    pub screen: Option<crate::Screen>,
    pub content: Option<crate::notch_layout::Content>,
    /// The last AppKit hardware notch reported for this panel's screen.
    pub hardware_notch: Option<HardwareNotch>,
    /// Placement target for that report; a screen change invalidates it before sizing.
    pub geometry_screen: Option<(i32, i32, i32, i32)>,
    pub insets: [f64; 4],
    pub hot: Vec<[f64; 4]>,
    pub expanded: bool,
    pub zoom: f64,
    /// Reject a stale completion after a later zoom request for this panel.
    pub zoom_seq: u64,
    pub base_dpr: f64,
    pub dpr_corrections: u32,
    pub landing: u32,
    pub landing_seq: u32,
    pub landing_hidden: u32,
    pub dragging: bool,
    pub pinned: bool,
    pub fullscreen: bool,
    pub surface: Option<SurfaceReport>,
}

/// Fade the whole NSWindow, including its native glass backing. JavaScript's
/// opacity affects only WKWebView and would leave the glass floating in place.
#[cfg(target_os = "macos")]
pub fn fade_edge(app: &AppHandle, label: &str, generation: u32) {
    let app = app.clone();
    let handle = app.clone();
    let label = label.to_owned();
    let _ = handle.run_on_main_thread(move || {
        use objc2_app_kit::{NSAnimatablePropertyContainer, NSAnimationContext, NSWindow};
        let Some(window) = app.get_webview_window(&label) else { return; };
        if !runtime(&label).lock().unwrap().edge_transition.begin_fade(generation) { return; }
        let Ok(ptr) = window.ns_window() else { return; };
        let native = unsafe { &*ptr.cast::<NSWindow>() };
        let changes = block2::RcBlock::new(|context: std::ptr::NonNull<NSAnimationContext>| {
            unsafe { context.as_ref() }.setDuration(0.16);
            native.animator().setAlphaValue(0.0);
        });
        let completion = block2::RcBlock::new(move || {
            crate::complete_edge_fade(&app, &label, generation);
        });
        NSAnimationContext::runAnimationGroup_completionHandler(&changes, Some(&completion));
    });
}

/// Called only on the UI thread, after the folded WebView has painted.
pub fn reveal_edge(window: &tauri::WebviewWindow) {
    #[cfg(target_os = "macos")]
    if let Ok(ptr) = window.ns_window() {
        let native = unsafe { &*ptr.cast::<objc2_app_kit::NSWindow>() };
        native.setAlphaValue(1.0);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = window;
}

#[derive(Clone, Copy, Debug, Deserialize)]
pub struct SurfaceSize {
    width: f64,
    height: f64,
}

#[derive(Clone, Copy, Debug, Deserialize)]
pub struct SurfaceRect {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    radius: f64,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SurfaceReport {
    viewport: SurfaceSize,
    pill: SurfaceRect,
    card: Option<SurfaceRect>,
    orb: Option<SurfaceRect>,
    /// Closed silhouette samples in viewport CSS coordinates, clockwise or counterclockwise.
    /// They are sampled from the same path the WebView uses to clip its content.
    pill_outline: Vec<[f64; 2]>,
    card_outline: Option<Vec<[f64; 2]>>,
    orb_outline: Option<Vec<[f64; 2]>>,
    folded: bool,
}

impl SurfaceReport {
    fn valid(&self) -> bool {
        let dimension = |v: f64| v.is_finite() && (1.0..=10_000.0).contains(&v);
        let rect = |r: SurfaceRect| {
            r.x.is_finite() && r.y.is_finite() && dimension(r.width) && dimension(r.height)
                && r.radius.is_finite() && r.radius >= 0.0 && r.radius <= 1_000.0
                && r.x >= -1_000.0 && r.y >= -1_000.0
                && r.x + r.width <= self.viewport.width + 1_000.0
                && r.y + r.height <= self.viewport.height + 1_000.0
        };
        dimension(self.viewport.width) && dimension(self.viewport.height)
            && rect(self.pill) && self.card.is_none_or(rect) && self.orb.is_none_or(rect)
            && valid_outline(&self.pill_outline, self.viewport)
            && self.card.is_some() == self.card_outline.is_some()
            && self.orb.is_some() == self.orb_outline.is_some()
            && self.card_outline.as_ref().is_none_or(|p| valid_outline(p, self.viewport))
            && self.orb_outline.as_ref().is_none_or(|p| valid_outline(p, self.viewport))
    }
}

fn valid_outline(points: &[[f64; 2]], viewport: SurfaceSize) -> bool {
    if !(3..=512).contains(&points.len()) || !points.iter().all(|p| {
        p[0].is_finite() && p[1].is_finite()
            && (-1_000.0..=viewport.width + 1_000.0).contains(&p[0])
            && (-1_000.0..=viewport.height + 1_000.0).contains(&p[1])
    }) { return false; }
    let (min_x, max_x) = points.iter().fold((f64::INFINITY, f64::NEG_INFINITY), |(a, b), p| (a.min(p[0]), b.max(p[0])));
    let (min_y, max_y) = points.iter().fold((f64::INFINITY, f64::NEG_INFINITY), |(a, b), p| (a.min(p[1]), b.max(p[1])));
    max_x - min_x >= 1.0 && max_y - min_y >= 1.0
}

static RUNTIMES: LazyLock<Mutex<HashMap<String, Arc<Mutex<WindowRuntime>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

type DisplayBounds = (i32, i32, i32, i32);
static DISPLAY_IDS: LazyLock<Mutex<HashMap<DisplayBounds, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn bounds(screen: &crate::Screen) -> DisplayBounds {
    (screen.x, screen.y, screen.w, screen.h)
}

pub fn cached_display_id(screen: &crate::Screen) -> Option<String> {
    DISPLAY_IDS.lock().unwrap().get(&bounds(screen)).cloned()
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct CGPoint {
    x: f64,
    y: f64,
}
#[cfg(target_os = "macos")]
#[repr(C)]
struct CGSize {
    width: f64,
    height: f64,
}
#[cfg(target_os = "macos")]
#[repr(C)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

#[cfg(target_os = "macos")]
fn scaled_display_bounds(rect: CGRect, pixels_wide: usize, pixels_high: usize, scale: f64) -> DisplayBounds {
    (
        (rect.origin.x * scale).round() as i32,
        (rect.origin.y * scale).round() as i32,
        (pixels_wide as f64 * scale).round() as i32,
        (pixels_high as f64 * scale).round() as i32,
    )
}

#[cfg(target_os = "macos")]
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGDisplayBounds(display: u32) -> CGRect;
    fn CGDisplayPixelsWide(display: u32) -> usize;
    fn CGDisplayPixelsHigh(display: u32) -> usize;
}
#[cfg(target_os = "macos")]
#[link(name = "ColorSync", kind = "framework")]
extern "C" {
    fn CGDisplayCreateUUIDFromDisplayID(display: u32) -> *const std::ffi::c_void;
}
#[cfg(target_os = "macos")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFUUIDCreateString(
        allocator: *const std::ffi::c_void,
        uuid: *const std::ffi::c_void,
    ) -> *const std::ffi::c_void;
    fn CFStringGetCString(
        string: *const std::ffi::c_void,
        buffer: *mut std::ffi::c_char,
        size: isize,
        encoding: u32,
    ) -> u8;
    fn CFRelease(value: *const std::ffi::c_void);
}

#[cfg(target_os = "macos")]
fn display_uuid(display: u32) -> Option<String> {
    if display == 0 {
        return None;
    }
    // ColorSync's Create and CoreFoundation's Create each hand us a retained object.
    unsafe {
        let uuid = CGDisplayCreateUUIDFromDisplayID(display);
        if uuid.is_null() {
            return None;
        }
        let string = CFUUIDCreateString(std::ptr::null(), uuid);
        CFRelease(uuid);
        if string.is_null() {
            return None;
        }
        let mut buffer = [0i8; 64];
        let ok = CFStringGetCString(
            string,
            buffer.as_mut_ptr(),
            buffer.len() as isize,
            0x0800_0100,
        );
        CFRelease(string);
        if ok == 0 {
            return None;
        }
        std::ffi::CStr::from_ptr(buffer.as_ptr())
            .to_str()
            .ok()
            .map(str::to_owned)
    }
}

/// Match Tao's scaled CoreGraphics coordinates to Tauri Monitor's physical bounds. The
/// resulting ColorSync UUID is stable across display reconfiguration.
#[cfg(target_os = "macos")]
fn refresh_display_ids(screens: &mut [crate::Screen]) {
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSScreen;
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let mut identities = HashMap::new();
    for native in NSScreen::screens(mtm).iter() {
        let id = native.CGDirectDisplayID();
        let Some(uuid) = display_uuid(id) else {
            continue;
        };
        let rect = unsafe { CGDisplayBounds(id) };
        let scale = native.backingScaleFactor();
        identities.insert(scaled_display_bounds(rect,
            unsafe { CGDisplayPixelsWide(id) }, unsafe { CGDisplayPixelsHigh(id) }, scale), uuid);
    }
    for screen in screens {
        screen.stable_id = identities.get(&bounds(screen)).cloned();
    }
    *DISPLAY_IDS.lock().unwrap() = identities;
}

pub fn is_notch_label(label: &str) -> bool {
    label == "notch" || label.starts_with("notch-display-")
}

pub fn runtime(label: &str) -> Arc<Mutex<WindowRuntime>> {
    RUNTIMES
        .lock()
        .unwrap()
        .entry(label.to_string())
        .or_insert_with(|| {
            Arc::new(Mutex::new(WindowRuntime {
                zoom: 1.0,
                ..Default::default()
            }))
        })
        .clone()
}

pub fn retire(label: &str) {
    RUNTIMES.lock().unwrap().remove(label);
    #[cfg(target_os = "macos")]
    retire_glass_on_main_thread(label);
}

/// CSS reports only geometry; material itself is always an AppKit view below the transparent
/// WebView. Folded and hardware-bridge portions stay opaque black in the page.
#[tauri::command]
pub async fn report_native_surface(
    app: AppHandle,
    window: tauri::WebviewWindow,
    report: SurfaceReport,
) -> Result<SurfaceCapability, String> {
    if !is_notch_label(window.label()) || !report.valid() {
        return Err("Invalid native notch surface geometry".into());
    }
    #[cfg(target_os = "macos")]
    {
        let (tx, mut rx) = tauri::async_runtime::channel(1);
        let handle = app.clone();
        app.run_on_main_thread(move || {
            let capability = apply_surface_on_main_thread(&handle, &window, &report);
            if capability.glass_available || capability.effective_surface_style == "solid" {
                runtime(window.label()).lock().unwrap().surface = Some(report);
            }
            let _ = handle.emit_to(window.label(), "native_notch_surface", &capability);
            let _ = tx.try_send(capability);
        })
            .map_err(|e| e.to_string())?;
        rx.recv().await.ok_or_else(|| "Could not install native notch material".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, window, report);
        Ok(surface_capability("solid", false, false))
    }
}

/// Reconcile on a later UI-loop turn. Constructing a WebView inside a synchronous IPC handler
/// deadlocks WebView2, and the same scheduling keeps this path safe if macOS dispatch changes.
pub fn schedule_reconcile(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let handle = app.clone();
        std::thread::spawn(move || {
            let app = handle.clone();
            let _ = handle.run_on_main_thread(move || reconcile_on_main_thread(&app));
        });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = app;
}

#[cfg(target_os = "macos")]
fn label_for_screen(screen: &crate::Screen) -> String {
    if let Some(id) = &screen.stable_id {
        return format!("notch-display-{}", id.to_ascii_lowercase());
    }
    // AppKit can transiently lack a CGDisplay UUID during hot plug. Keep one panel visible
    // by name until the next reconciliation supplies its persistent identity.
    let fallback = screen.name.as_deref().unwrap_or("display");
    let safe: String = fallback
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(32)
        .collect();
    format!("notch-display-transient-{safe}")
}

#[cfg(target_os = "macos")]
fn reconcile_on_main_thread(app: &AppHandle) {
    use std::collections::HashSet;
    use tauri::{WebviewUrl, WebviewWindowBuilder};
    let (all_displays, visible) = {
        let st = app.state::<crate::AppState>();
        let cfg = st.cfg.lock().unwrap();
        (
            cfg.appearance.notch_scope == "allDisplays",
            cfg.notch_visible,
        )
    };
    let mut screens = crate::screens(app);
    refresh_display_ids(&mut screens);
    let base = runtime("notch");
    base.lock().unwrap().screen = if all_displays {
        screens.first().cloned()
    } else {
        None
    };
    let mut desired = HashSet::new();
    if all_displays {
        for screen in screens.iter().skip(1) {
            let label = label_for_screen(screen);
            if !desired.insert(label.clone()) {
                continue;
            }
            runtime(&label).lock().unwrap().screen = Some(screen.clone());
            if app.get_webview_window(&label).is_some() {
                continue;
            }
            let builder =
                WebviewWindowBuilder::new(app, &label, WebviewUrl::App("notch.html".into()))
                    .inner_size(crate::NOTCH_W, crate::NOTCH_LONG)
                    .transparent(true)
                    .decorations(false)
                    .always_on_top(true)
                    .skip_taskbar(true)
                    .resizable(false)
                    .shadow(false)
                    .visible(false)
                    .focused(false)
                    .focusable(false);
            match builder.build() {
                Ok(window) => {
                    crate::notch_window::configure(&window);
                    crate::notchmenu::attach(&window);
                    crate::start_pointer_watchdog(app.clone(), label.clone());
                    if visible {
                        let _ = window.show();
                    }
                }
                Err(error) => {
                    retire(&label);
                    crate::applog(&format!("notch display window {label}: {error}"));
                }
            }
        }
    }
    for window in app.webview_windows().values() {
        let label = window.label();
        if label.starts_with("notch-display-") && !desired.contains(label) {
            let _ = window.close();
            retire(label);
        }
    }
    crate::place_notch(app);
    apply_preferences_to_windows_on_main_thread(app);
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
pub struct HardwareNotch {
    pub width: f64,
    pub height: f64,
}

#[derive(Clone, Debug, Serialize)]
pub struct NativeNotchGeometry {
    pub hardware_notch: Option<HardwareNotch>,
}

fn hardware_notch(
    frame_width: f64,
    left_width: f64,
    right_width: f64,
    top_inset: f64,
) -> Option<HardwareNotch> {
    let width = frame_width - left_width - right_width;
    if !width.is_finite() || !top_inset.is_finite() || width <= 0.0 || top_inset <= 0.0 {
        return None;
    }
    Some(HardwareNotch {
        width,
        height: top_inset,
    })
}

#[cfg(target_os = "macos")]
fn geometry_on_main_thread(window: &tauri::WebviewWindow) -> NativeNotchGeometry {
    use objc2_app_kit::NSWindow;
    let hardware_notch = window.ns_window().ok().and_then(|ptr| {
        // The webview window owns this NSWindow. We only borrow it during this UI-thread callback.
        let native = unsafe { &*ptr.cast::<NSWindow>() };
        let screen = native.screen()?;
        let frame = screen.frame();
        let left = screen.auxiliaryTopLeftArea();
        let right = screen.auxiliaryTopRightArea();
        hardware_notch(
            frame.size.width,
            left.size.width,
            right.size.width,
            screen.safeAreaInsets().top,
        )
    });
    NativeNotchGeometry { hardware_notch }
}

#[cfg(not(target_os = "macos"))]
fn geometry_on_main_thread(_: &tauri::WebviewWindow) -> NativeNotchGeometry {
    NativeNotchGeometry {
        hardware_notch: None,
    }
}

fn remember_geometry(window: &tauri::WebviewWindow, geometry: &NativeNotchGeometry) -> bool {
    let runtime = runtime(window.label());
    let mut current = runtime.lock().unwrap();
    let changed = current.hardware_notch != geometry.hardware_notch;
    current.hardware_notch = geometry.hardware_notch;
    changed
}

/// A newly loaded notch asks for its own screen geometry. The caller window is injected by
/// Tauri, so Settings cannot accidentally obtain or overwrite a different panel's geometry.
#[tauri::command]
pub async fn get_native_notch_geometry(
    app: AppHandle,
    window: tauri::WebviewWindow,
) -> Result<NativeNotchGeometry, String> {
    #[cfg(target_os = "macos")]
    {
        let (tx, mut rx) = tauri::async_runtime::channel(1);
        let handle = app.clone();
        app.run_on_main_thread(move || {
            let geometry = geometry_on_main_thread(&window);
            let changed = remember_geometry(&window, &geometry);
            let _ = tx.try_send(geometry);
            if changed { crate::place_notch(&handle); }
        })
        .map_err(|e| e.to_string())?;
        rx.recv()
            .await
            .ok_or_else(|| "Could not read display geometry".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        let geometry = geometry_on_main_thread(&window);
        remember_geometry(&window, &geometry);
        Ok(geometry)
    }
}

/// Placement can change which NSScreen owns the panel. Re-read from the actual NSWindow once
/// AppKit has processed the move, then target just that window's page.
pub fn notify_geometry(app: &AppHandle, label: &str) {
    let Some(window) = app.get_webview_window(label) else {
        return;
    };
    #[cfg(target_os = "macos")]
    {
        let handle = app.clone();
        let _ = app.run_on_main_thread(move || {
            let geometry = geometry_on_main_thread(&window);
            let changed = remember_geometry(&window, &geometry);
            let _ = handle.emit_to(
                window.label(),
                "native_notch_geometry",
                geometry,
            );
            if changed { crate::place_notch(&handle); }
        });
    }
    #[cfg(not(target_os = "macos"))]
    {
        let geometry = geometry_on_main_thread(&window);
        remember_geometry(&window, &geometry);
        let _ = app.emit_to(
            window.label(),
            "native_notch_geometry",
            geometry,
        );
    }
}

/// Effective material is reported separately from the saved choice until every WebView shape
/// has a native glass backing. This prevents a macOS 26+ picker from claiming a CSS imitation.
#[derive(Clone, Debug, Serialize)]
pub struct SurfaceCapability {
    /// OS-level eligibility for the Settings picker. Unlike `glass_available`, this does not
    /// depend on whether the notch WebView has reported its outline yet.
    pub supported: bool,
    pub glass_available: bool,
    pub reduce_transparency: bool,
    pub effective_surface_style: String,
}

fn surface_capability(chosen: &str, reduce_transparency: bool, glass_available: bool) -> SurfaceCapability {
    #[cfg(target_os = "macos")]
    let supported = glass_available_on_main_thread();
    #[cfg(not(target_os = "macos"))]
    let supported = false;
    SurfaceCapability {
        supported,
        glass_available,
        reduce_transparency,
        effective_surface_style: if chosen == "solid" || !glass_available || reduce_transparency {
            "solid".into()
        } else {
            chosen.into()
        },
    }
}

#[cfg(target_os = "macos")]
fn glass_available_on_main_thread() -> bool {
    objc2_foundation::NSProcessInfo::processInfo().operatingSystemVersion().majorVersion >= 26
}

#[cfg(target_os = "macos")]
struct GlassPair {
    dim: objc2::rc::Retained<objc2_app_kit::NSView>,
    glass: objc2::rc::Retained<objc2_app_kit::NSGlassEffectView>,
    dim_mask: objc2::rc::Retained<objc2_quartz_core::CAShapeLayer>,
    glass_mask: objc2::rc::Retained<objc2_quartz_core::CAShapeLayer>,
}

#[cfg(target_os = "macos")]
impl GlassPair {
    fn new(parent: &objc2_app_kit::NSView, webview: Option<&objc2_app_kit::NSView>,
        mtm: objc2::MainThreadMarker) -> Option<Self> {
        use objc2_app_kit::{NSGlassEffectView, NSView, NSWindowOrderingMode};
        let dim = NSView::new(mtm);
        dim.setWantsLayer(true);
        let dim_mask = objc2_quartz_core::CAShapeLayer::new();
        let dim_layer = dim.layer()?;
        unsafe { dim_layer.setMask(Some(&dim_mask)); }
        let glass = NSGlassEffectView::new(mtm);
        glass.setWantsLayer(true);
        let glass_mask = objc2_quartz_core::CAShapeLayer::new();
        let glass_layer = glass.layer()?;
        unsafe { glass_layer.setMask(Some(&glass_mask)); }
        dim.setHidden(true);
        glass.setHidden(true);
        parent.addSubview_positioned_relativeTo(&dim, NSWindowOrderingMode::Below, webview);
        parent.addSubview_positioned_relativeTo(&glass, NSWindowOrderingMode::Below, webview);
        Some(Self { dim, glass, dim_mask, glass_mask })
    }

    fn hide(&self) {
        self.dim.setHidden(true);
        self.glass.setHidden(true);
    }

    fn show(&self, frame: objc2_foundation::NSRect, points: &[objc2_foundation::NSPoint], dark: bool, dim_alpha: f64) {
        use objc2_app_kit::{NSColor, NSGlassEffectViewStyle};
        let path = objc2_core_graphics::CGMutablePath::new();
        // The points were validated and converted to this view's local coordinates.
        unsafe { objc2_core_graphics::CGMutablePath::add_lines(
            Some(&path), std::ptr::null(), points.as_ptr(), points.len()
        ) };
        objc2_core_graphics::CGMutablePath::close_subpath(Some(&path));
        let mask_frame = objc2_foundation::NSRect {
            origin: objc2_foundation::NSPoint { x: 0.0, y: 0.0 },
            size: frame.size,
        };
        self.dim_mask.setFrame(mask_frame);
        self.glass_mask.setFrame(mask_frame);
        self.dim_mask.setPath(Some(&path));
        self.glass_mask.setPath(Some(&path));
        self.dim.setFrame(frame);
        if let Some(layer) = self.dim.layer() {
            let color = NSColor::blackColor().colorWithAlphaComponent(dim_alpha).CGColor();
            layer.setBackgroundColor(Some(&color));
        }
        self.dim.setHidden(dim_alpha <= 0.0);
        self.glass.setFrame(frame);
        self.glass.setCornerRadius(0.0);
        self.glass.setStyle(if dark { NSGlassEffectViewStyle::Clear } else { NSGlassEffectViewStyle::Regular });
        self.glass.setHidden(false);
    }

    fn remove(self) {
        self.glass.removeFromSuperview();
        self.dim.removeFromSuperview();
    }
}

#[cfg(target_os = "macos")]
struct GlassBacking { pill: GlassPair, card: GlassPair, orb: GlassPair }

#[cfg(target_os = "macos")]
impl GlassBacking {
    fn new(window: &tauri::WebviewWindow, mtm: objc2::MainThreadMarker) -> Option<Self> {
        use objc2_app_kit::NSWindow;
        let ptr = window.ns_window().ok()?;
        let native = unsafe { &*ptr.cast::<NSWindow>() };
        let parent = native.contentView()?;
        let siblings = parent.subviews();
        let webview = siblings.firstObject();
        Some(Self {
            pill: GlassPair::new(&parent, webview.as_deref(), mtm)?,
            card: GlassPair::new(&parent, webview.as_deref(), mtm)?,
            orb: GlassPair::new(&parent, webview.as_deref(), mtm)?,
        })
    }

    fn hide(&self) { self.pill.hide(); self.card.hide(); self.orb.hide(); }
    fn remove(self) { self.pill.remove(); self.card.remove(); self.orb.remove(); }
}

#[cfg(target_os = "macos")]
thread_local! {
    static GLASS: std::cell::RefCell<HashMap<String, GlassBacking>> =
        std::cell::RefCell::new(HashMap::new());
}

#[cfg(target_os = "macos")]
fn retire_glass_on_main_thread(label: &str) {
    if objc2::MainThreadMarker::new().is_none() { return; }
    GLASS.with(|map| {
        if let Some(backing) = map.borrow_mut().remove(label) { backing.remove(); }
    });
}

#[cfg(target_os = "macos")]
fn native_outline(points: &[[f64; 2]], viewport: SurfaceSize, bounds: objc2_foundation::NSRect)
    -> (objc2_foundation::NSRect, Vec<objc2_foundation::NSPoint>) {
    use objc2_foundation::{NSPoint, NSRect, NSSize};
    let sx = bounds.size.width / viewport.width;
    let sy = bounds.size.height / viewport.height;
    let native: Vec<NSPoint> = points.iter().map(|p| NSPoint {
        x: bounds.origin.x + p[0] * sx,
        y: bounds.origin.y + bounds.size.height - p[1] * sy,
    }).collect();
    let min_x = native.iter().map(|p| p.x).fold(f64::INFINITY, f64::min);
    let max_x = native.iter().map(|p| p.x).fold(f64::NEG_INFINITY, f64::max);
    let min_y = native.iter().map(|p| p.y).fold(f64::INFINITY, f64::min);
    let max_y = native.iter().map(|p| p.y).fold(f64::NEG_INFINITY, f64::max);
    let frame = NSRect { origin: NSPoint { x: min_x, y: min_y },
        size: NSSize { width: max_x - min_x, height: max_y - min_y } };
    let local = native.into_iter().map(|p| NSPoint { x: p.x - min_x, y: p.y - min_y }).collect();
    (frame, local)
}

#[cfg(target_os = "macos")]
fn apply_surface_on_main_thread(app: &AppHandle, window: &tauri::WebviewWindow, report: &SurfaceReport) -> SurfaceCapability {
    use objc2_app_kit::NSWindow;
    let chosen = app.state::<crate::AppState>().cfg.lock().unwrap().appearance.surface_style.clone();
    let reduce = objc2_app_kit::NSWorkspace::sharedWorkspace()
        .accessibilityDisplayShouldReduceTransparency();
    let fallback = surface_capability(&chosen, reduce, false);
    if !glass_available_on_main_thread() {
        crate::notch_window::apply_appearance(window, false);
        return fallback;
    }
    let Some(mtm) = objc2::MainThreadMarker::new() else { return fallback };
    let Ok(ptr) = window.ns_window() else { return fallback };
    let native = unsafe { &*ptr.cast::<NSWindow>() };
    let Some(parent) = native.contentView() else { return fallback };
    let bounds = parent.bounds();
    let capability = surface_capability(&chosen, reduce, true);
    let effective = capability.effective_surface_style.as_str();
    let dark_appearance = {
        use objc2_app_kit::{NSAppearanceCustomization, NSAppearanceNameAqua, NSAppearanceNameDarkAqua};
        let names = objc2_foundation::NSArray::from_slice(&[unsafe { NSAppearanceNameDarkAqua }, unsafe { NSAppearanceNameAqua }]);
        native.effectiveAppearance().bestMatchFromAppearancesWithNames(&names)
            .is_some_and(|name| name.to_string() == unsafe { NSAppearanceNameDarkAqua }.to_string())
    };
    let installed = GLASS.with(|map| {
        let mut map = map.borrow_mut();
        if !map.contains_key(window.label()) {
            let Some(created) = GlassBacking::new(window, mtm) else { return false };
            map.insert(window.label().to_string(), created);
        }
        let Some(backing) = map.get(window.label()) else { return false };
        if effective == "solid" || report.folded {
            backing.hide();
            return true;
        }
        let dark = effective == "darkGlass";
        let (frame, points) = native_outline(&report.pill_outline, report.viewport, bounds);
        backing.pill.show(frame, &points, dark, if dark { 0.60 } else { 0.0 });
        if let Some(outline) = &report.card_outline {
            let (frame, points) = native_outline(outline, report.viewport, bounds);
            let card_dim = if dark { 0.80 } else if dark_appearance { 0.35 } else { 0.0 };
            backing.card.show(frame, &points, dark, card_dim);
        } else { backing.card.hide(); }
        if let Some(outline) = &report.orb_outline {
            let (frame, points) = native_outline(outline, report.viewport, bounds);
            backing.orb.show(frame, &points, dark, if dark { 0.60 } else { 0.0 });
        } else { backing.orb.hide(); }
        true
    });
    crate::notch_window::apply_appearance(window, installed && effective == "glass");
    if installed { capability } else { fallback }
}

#[tauri::command]
pub async fn get_surface_capability(app: AppHandle, window: tauri::WebviewWindow) -> Result<SurfaceCapability, String> {
    let chosen = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .appearance
        .surface_style
        .clone();
    #[cfg(target_os = "macos")]
    {
        let (tx, mut rx) = tauri::async_runtime::channel(1);
        app.run_on_main_thread(move || {
            let reduce = objc2_app_kit::NSWorkspace::sharedWorkspace()
                .accessibilityDisplayShouldReduceTransparency();
            let installed = GLASS.with(|map| map.borrow().contains_key(window.label()));
            let available = glass_available_on_main_thread() && installed;
            let _ = tx.try_send(surface_capability(&chosen, reduce, available));
        })
        .map_err(|e| e.to_string())?;
        rx.recv()
            .await
            .ok_or_else(|| "Could not read surface capability".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(surface_capability(&chosen, false, false))
    }
}

pub fn apply_preferences(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    schedule_reconcile(app);
    #[cfg(not(target_os = "macos"))]
    {
        let chosen = app
            .state::<crate::AppState>()
            .cfg
            .lock()
            .unwrap()
            .appearance
            .surface_style
            .clone();
        let _ = app.emit("native_notch_surface", surface_capability(&chosen, false, false));
    }
}

#[cfg(target_os = "macos")]
fn apply_preferences_to_windows_on_main_thread(app: &AppHandle) {
    let chosen = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .appearance
        .surface_style
        .clone();
    let reduce = objc2_app_kit::NSWorkspace::sharedWorkspace()
        .accessibilityDisplayShouldReduceTransparency();
    let capability = surface_capability(&chosen, reduce, glass_available_on_main_thread());
    for window in app
        .webview_windows()
        .values()
        .filter(|w| is_notch_label(w.label()))
    {
        let report = { runtime(window.label()).lock().unwrap().surface.clone() };
        if let Some(report) = report {
            let actual = apply_surface_on_main_thread(app, window, &report);
            let _ = app.emit_to(window.label(), "native_notch_surface", actual);
        } else {
            crate::notch_window::apply_appearance(window, false);
            let _ = app.emit_to(window.label(), "native_notch_surface", surface_capability(&chosen, reduce, false));
        }
    }
    let _ = capability;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hardware_notch_uses_menu_bar_strips_and_safe_inset() {
        assert_eq!(
            hardware_notch(1512.0, 650.0, 650.0, 37.0),
            Some(HardwareNotch {
                width: 212.0,
                height: 37.0
            })
        );
        assert_eq!(hardware_notch(1512.0, 0.0, 0.0, 0.0), None);
        assert_eq!(hardware_notch(1512.0, 760.0, 760.0, 37.0), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn display_identity_uses_tao_physical_coordinates_on_retina() {
        let rect = CGRect { origin: CGPoint { x: 1440.0, y: -120.0 },
            size: CGSize { width: 1512.0, height: 982.0 } };
        assert_eq!(scaled_display_bounds(rect, 1512, 982, 2.0), (2880, -240, 3024, 1964));
    }

    #[test]
    fn surface_requires_a_real_bounded_shape_for_every_visible_piece() {
        let rect = SurfaceRect { x: 0.0, y: 0.0, width: 40.0, height: 40.0, radius: 8.0 };
        let mut report = SurfaceReport {
            viewport: SurfaceSize { width: 360.0, height: 900.0 },
            pill: rect, card: None, orb: None,
            pill_outline: vec![[0.0, 0.0], [40.0, 0.0], [40.0, 40.0], [0.0, 40.0]],
            card_outline: None, orb_outline: None, folded: false,
        };
        assert!(report.valid());
        report.card = Some(rect);
        assert!(!report.valid()); // a rectangular glass card may not stand in for its tail
        report.card_outline = Some(vec![[40.0, 0.0], [80.0, 0.0], [60.0, 40.0]]);
        assert!(report.valid());
        report.card_outline.as_mut().unwrap()[1][0] = f64::INFINITY;
        assert!(!report.valid());
    }
}
