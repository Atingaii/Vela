//! The settings window. Created when it is opened and destroyed when it is closed, so no second
//! WebView sits hidden for the life of the app. The Swift baseline uses a solid dark
//! surface on both platforms; wallpaper and system light mode must not alter it.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "settings";

/// The Swift app menu keeps Settings available even when the notch is hidden.
pub fn install_app_menu(app: &AppHandle) -> tauri::Result<()> {
    #[cfg(target_os = "macos")]
    {
        use tauri::menu::{Menu, MenuItemBuilder};
        let menu = Menu::default(app)?;
        if let Some(submenu) = menu.items()?.first().and_then(|i| i.as_submenu()) {
            let settings = MenuItemBuilder::with_id(
                "app:settings",
                crate::i18n::tr(&crate::tray::language(app), "settings"),
            )
            .accelerator("CmdOrCtrl+,")
            .build(app)?;
            submenu.insert(&settings, 2)?;
        }
        app.set_menu(menu)?;
        app.on_menu_event(|app, event| {
            if event.id().as_ref() == "app:settings" {
                open(app);
            }
        });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = app;
    Ok(())
}
/// Always built on a later turn of the event loop. A window built inside a synchronous command
/// deadlocks WebView2 and comes up blank, and asking `run_on_main_thread` from the main thread —
/// where those commands run — builds it on the spot, so the request is posted from another thread.
pub fn open(app: &AppHandle) {
    let handle = app.clone();
    std::thread::spawn(move || {
        let app = handle.clone();
        let _ = handle.run_on_main_thread(move || open_now(&app));
    });
}

fn open_now(app: &AppHandle) {
    if let Some(w) = app.get_webview_window(LABEL) {
        #[cfg(target_os = "macos")]
        let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
        return;
    }
    // SettingsWindowController: a titled, transparent, dark NSWindow, with content under the
    // titlebar. Removing decorations on macOS removes the traffic lights as well.
    let builder = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("settings.html".into()))
        .title("Velo Settings")
        .initialization_script(if crate::smoke::root().is_some() && !crate::smoke::visual() { crate::smoke::PAGE_CHECK } else { "" })
        .initialization_script(if cfg!(target_os = "macos") {
            "document.addEventListener('DOMContentLoaded',()=>document.documentElement.dataset.platform='macos');"
        } else { "" })
        .inner_size(860.0, 600.0)
        .resizable(false)
        .maximizable(false)
        .decorations(cfg!(target_os = "macos"))
        .transparent(true)
        .theme(Some(tauri::Theme::Dark))
        .shadow(true)
        .center();
    #[cfg(target_os = "macos")]
    let builder = builder
        .title_bar_style(tauri::TitleBarStyle::Overlay)
        .hidden_title(true)
        .traffic_light_position(tauri::LogicalPosition::new(20.0, 20.0));
    match builder.build() {
        // Raised again once it exists: a window created while the app is not in front can come up behind
        Ok(w) => {
            #[cfg(target_os = "macos")]
            {
                let _ = app.set_activation_policy(tauri::ActivationPolicy::Regular);
                layout_traffic_lights(&w);
            }
            let handle = app.clone();
            w.on_window_event(move |event| {
                if matches!(
                    event,
                    tauri::WindowEvent::CloseRequested { .. } | tauri::WindowEvent::Destroyed
                ) {
                    // A closing WebView cannot reliably finish a pagehide IPC request.
                    let _ = crate::phone_link::phone_pairing(false);
                }
                #[cfg(target_os = "macos")]
                if matches!(event, tauri::WindowEvent::Destroyed) {
                    // Tauri may still have the destroyed window in its manager during this callback.
                    apply_macos_presence(&handle, false);
                }
                if matches!(event, tauri::WindowEvent::Focused(true)) {
                    #[cfg(target_os = "macos")]
                    if let Some(window) = handle.get_webview_window(LABEL) {
                        layout_traffic_lights(&window);
                    }
                }
            });
            let _ = w.set_focus();
        }
        Err(e) => crate::applog(&format!("settings window: {e}")),
    }
}

/// Swift AppPresence: a Dock app by default, menu-bar only, or neither. Settings temporarily
/// promotes an accessory app until it closes. Reopening the application remains a way back.
pub fn apply_presence(app: &AppHandle) {
    #[cfg(target_os = "macos")]
    apply_macos_presence(app, app.get_webview_window(LABEL).is_some());
    #[cfg(not(target_os = "macos"))]
    let _ = app;
}

#[cfg(target_os = "macos")]
fn apply_macos_presence(app: &AppHandle, settings_open: bool) {
    let mode = app
        .state::<crate::AppState>()
        .cfg
        .lock()
        .unwrap()
        .appearance
        .app_presence
        .clone();
    let policy = if mode == "dock" || settings_open {
        tauri::ActivationPolicy::Regular
    } else {
        tauri::ActivationPolicy::Accessory
    };
    let _ = app.set_activation_policy(policy);
    if let Some(tray) = app.tray_by_id("main") {
        let _ = tray.set_visible(mode == "menuBar");
    }
}

/// Pinned Swift SettingsWindowController.layoutTrafficLights: centres 26 / 48.5 / 71,
/// centred vertically in the 52 pt header. Run on the UI thread, including after activation.
#[cfg(target_os = "macos")]
fn layout_traffic_lights(window: &tauri::WebviewWindow) {
    use objc2_app_kit::{NSWindow, NSWindowButton};
    let Ok(ptr) = window.ns_window() else { return };
    // Tauri owns this NSWindow; this borrowed reference never leaves the UI callback.
    let window = unsafe { &*ptr.cast::<NSWindow>() };
    for (index, kind) in [
        NSWindowButton::CloseButton,
        NSWindowButton::MiniaturizeButton,
        NSWindowButton::ZoomButton,
    ]
    .into_iter()
    .enumerate()
    {
        if let Some(button) = window.standardWindowButton(kind) {
            // The standard button and its retained parent are both owned by this live NSWindow.
            if let Some(container) = unsafe { button.superview() } {
                let mut frame = button.frame();
                frame.origin.x = 26.0 + index as f64 * 22.5 - frame.size.width / 2.0;
                frame.origin.y = container.bounds().size.height - 26.0 - frame.size.height / 2.0;
                button.setFrameOrigin(frame.origin);
            }
        }
    }
}

#[derive(serde::Serialize)]
pub struct SystemLook {
    mica: bool,
    /// The accent palette as #rrggbb: light 3, light 2, light 1, accent, dark 1, dark 2, dark 3.
    accent: Vec<String>,
    symbols: std::collections::BTreeMap<String, SystemSymbol>,
}

#[derive(serde::Serialize)]
struct SystemSymbol {
    url: String,
    width: f64,
    height: f64,
}

#[cfg(target_os = "macos")]
fn system_symbol_from_png(bytes: &[u8], width: f64, height: f64) -> Option<SystemSymbol> {
    use base64::Engine;
    // Check the actual encoded output, not only AppKit's source image. A malformed or fully
    // transparent representation should use the existing CSS fallback instead.
    let decoded = tauri::image::Image::from_bytes(bytes).ok()?;
    if !(1.0..=128.0).contains(&width)
        || !(1.0..=128.0).contains(&height)
        || !(1..=512).contains(&decoded.width())
        || !(1..=512).contains(&decoded.height())
        || !decoded.rgba().chunks_exact(4).any(|pixel| pixel[3] > 0)
    {
        return None;
    }
    Some(SystemSymbol {
        url: format!(
            "data:image/png;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(bytes)
        ),
        width,
        height,
    })
}

/// Render the same SF Symbols that SwiftUI requests, on the user's Mac. No exported Apple
/// artwork is shipped in the cross-platform assets. Other platforms keep their vector fallback.
fn settings_symbols() -> std::collections::BTreeMap<String, SystemSymbol> {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{
            NSBitmapImageFileType, NSBitmapImageRep, NSImage, NSImageSymbolConfiguration,
        };
        use objc2_foundation::{NSDictionary, NSString};
        [
            ("accounts", "person.crop.circle.fill", 13.0),
            ("phone", "iphone", 13.0),
            ("custom", "network", 12.0),
            ("appearance", "paintbrush.fill", 13.0),
            ("notifications", "bell.badge.fill", 13.0),
            ("general", "gearshape.fill", 13.0),
            ("quit", "power", 13.0),
        ]
        .into_iter()
        .filter_map(|(id, name, size)| {
            let image = NSImage::imageWithSystemSymbolName_accessibilityDescription(
                &NSString::from_str(name),
                None,
            )?;
            let config = NSImageSymbolConfiguration::configurationWithPointSize_weight(size, 0.0);
            let image = image.imageWithSymbolConfiguration(&config)?;
            let size = image.size();
            let tiff = image.TIFFRepresentation()?;
            let bitmap = NSBitmapImageRep::imageRepWithData(&tiff)?;
            // The properties dictionary is empty, so it contains no incorrectly typed values.
            let data = unsafe {
                bitmap.representationUsingType_properties(
                    NSBitmapImageFileType::PNG,
                    &NSDictionary::new(),
                )
            }?;
            // NSData is owned by this call and never mutated while the byte slice is borrowed.
            let bytes = unsafe { data.as_bytes_unchecked() };
            system_symbol_from_png(bytes, size.width, size.height).map(|symbol| (id.into(), symbol))
        })
        .collect()
    }
    #[cfg(not(target_os = "macos"))]
    std::collections::BTreeMap::new()
}

fn render_system_look() -> SystemLook {
    #[cfg(target_os = "macos")]
    let accent = {
        use objc2_app_kit::{NSColor, NSColorSpace};
        NSColor::controlAccentColor()
            .colorUsingColorSpace(&NSColorSpace::sRGBColorSpace())
            .map(|c| {
                let byte = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
                let hex = format!(
                    "#{:02x}{:02x}{:02x}",
                    byte(c.redComponent()),
                    byte(c.greenComponent()),
                    byte(c.blueComponent())
                );
                vec![hex; 7]
            })
            .unwrap_or_default()
    };
    #[cfg(not(target_os = "macos"))]
    let accent = reg_binary(
        r"Software\Microsoft\Windows\CurrentVersion\Explorer\Accent",
        "AccentPalette",
    )
    .map(|bytes| palette(&bytes))
    .unwrap_or_default();
    SystemLook {
        mica: false,
        accent,
        symbols: settings_symbols(),
    }
}

/// AppKit's symbol rasterization and accent colour lookup run on the UI thread. The async
/// command does not block that thread while waiting for the result.
#[tauri::command]
pub async fn get_system_look(app: AppHandle) -> Result<SystemLook, String> {
    #[cfg(target_os = "macos")]
    {
        let (tx, mut rx) = tauri::async_runtime::channel(1);
        app.run_on_main_thread(move || {
            let _ = tx.try_send(render_system_look());
        })
        .map_err(|e| e.to_string())?;
        rx.recv()
            .await
            .ok_or_else(|| "Could not render system look".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Ok(render_system_look())
    }
}

#[tauri::command]
pub fn quit_app(app: AppHandle) {
    app.exit(0);
}

/// The credit line's link, as on the Mac.
#[tauri::command]
pub fn open_author_page() {
    let _ = crate::platform::open(std::ffi::OsStr::new("https://github.com/Atingaii/Velo"));
}

#[cfg(any(not(target_os = "macos"), test))]
fn palette(bytes: &[u8]) -> Vec<String> {
    let (colours, _) = bytes.as_chunks::<4>();
    colours
        .iter()
        .take(7)
        .map(|c| format!("#{:02x}{:02x}{:02x}", c[0], c[1], c[2]))
        .collect()
}

#[cfg(windows)]
fn reg_binary(key: &str, value: &str) -> Option<Vec<u8>> {
    use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_BINARY};
    let mut data = vec![0u8; 64];
    let mut size = data.len() as u32;
    reg_get(
        HKEY_CURRENT_USER,
        key,
        value,
        RRF_RT_REG_BINARY,
        data.as_mut_ptr().cast(),
        &mut size,
    )
    .then(|| {
        data.truncate(size as usize);
        data
    })
}

#[cfg(windows)]
fn reg_get(
    root: windows::Win32::System::Registry::HKEY,
    key: &str,
    value: &str,
    kind: windows::Win32::System::Registry::REG_ROUTINE_FLAGS,
    data: *mut core::ffi::c_void,
    size: &mut u32,
) -> bool {
    use windows::core::HSTRING;
    use windows::Win32::System::Registry::RegGetValueW;
    let (key, value) = (HSTRING::from(key), HSTRING::from(value));
    unsafe { RegGetValueW(root, &key, &value, kind, None, Some(data), Some(size)) }.is_ok()
}

#[cfg(all(not(windows), not(target_os = "macos")))]
fn reg_binary(_key: &str, _value: &str) -> Option<Vec<u8>> {
    None
}

#[cfg(test)]
mod tests {
    use super::palette;

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn platforms_without_sf_symbols_use_the_vector_fallback() {
        assert!(super::settings_symbols().is_empty());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn symbol_png_must_decode_with_visible_alpha_and_reasonable_size() {
        use super::system_symbol_from_png;
        use base64::Engine;
        // Synthetic RGBA PNGs keep AppKit off Rust's test worker thread. The installed app
        // exercises the real SF Symbol rendering on its UI thread.
        let visible = base64::engine::general_purpose::STANDARD
            .decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAD0lEQVR4nGP4z8AAREgAAB7zAf9qN12tAAAAAElFTkSuQmCC")
            .unwrap();
        let transparent = base64::engine::general_purpose::STANDARD
            .decode("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAC0lEQVR4nGNgQAcAABIAAXfx+gAAAAAASUVORK5CYII=")
            .unwrap();
        let symbol = system_symbol_from_png(&visible, 13.0, 13.0).unwrap();
        assert!(symbol.url.starts_with("data:image/png;base64,"));
        let delivered = base64::engine::general_purpose::STANDARD
            .decode(symbol.url.trim_start_matches("data:image/png;base64,"))
            .unwrap();
        let decoded = tauri::image::Image::from_bytes(&delivered).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (2, 2));
        assert!(decoded.rgba().chunks_exact(4).any(|pixel| pixel[3] > 0));
        assert!(system_symbol_from_png(&transparent, 13.0, 13.0).is_none());
        assert!(system_symbol_from_png(&visible, 0.0, 13.0).is_none());
        assert!(system_symbol_from_png(&visible, 513.0, 13.0).is_none());
        assert!(system_symbol_from_png(b"not a PNG", 13.0, 13.0).is_none());
    }

    #[test]
    fn the_palette_reads_seven_colours_and_drops_the_alpha_byte() {
        let mut bytes = Vec::new();
        for i in 0..8u8 {
            bytes.extend_from_slice(&[0x10 + i, 0x20 + i, 0x30 + i, 0xff]);
        }
        let colours = palette(&bytes);
        assert_eq!(colours.len(), 7);
        assert_eq!(colours[0], "#102030");
        assert_eq!(colours[6], "#162636");
    }
}
