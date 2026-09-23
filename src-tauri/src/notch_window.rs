//! Native properties of the pinned Swift NotchPanel that are not expressible as Tauri's
//! cross-platform `alwaysOnTop`. Focus remains disabled by the window configuration.
#[cfg(target_os = "macos")]
pub fn configure(window: &tauri::WebviewWindow) {
    use objc2_app_kit::{NSStatusWindowLevel, NSWindow, NSWindowCollectionBehavior};
    let Ok(ptr) = window.ns_window() else { return };
    // Called during setup on the UI thread; Tauri retains the NSWindow throughout this borrow.
    let native = unsafe { &*ptr.cast::<NSWindow>() };
    native.setLevel(NSStatusWindowLevel);
    native.setCollectionBehavior(
        NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::Stationary
            | NSWindowCollectionBehavior::FullScreenAuxiliary,
    );
    native.setMovable(false);
    native.setMovableByWindowBackground(false);
    native.setHidesOnDeactivate(false);
    native.setHasShadow(false);
}

/// Match Swift NotchSurfaceStyle.panelAppearance. An opaque black surface is always dark;
/// regular native glass (once its shapes are backed) should inherit the Mac's appearance.
#[cfg(target_os = "macos")]
pub fn apply_appearance(window: &tauri::WebviewWindow, inherit_system: bool) {
    use objc2_app_kit::{
        NSAppearance, NSAppearanceCustomization, NSAppearanceNameDarkAqua, NSWindow,
    };
    let Ok(ptr) = window.ns_window() else { return };
    let native = unsafe { &*ptr.cast::<NSWindow>() };
    let appearance = if inherit_system {
        None
    } else {
        NSAppearance::appearanceNamed(unsafe { NSAppearanceNameDarkAqua })
    };
    native.setAppearance(appearance.as_deref());
}

#[cfg(not(target_os = "macos"))]
pub fn configure(_: &tauri::WebviewWindow) {}

#[cfg(not(target_os = "macos"))]
pub fn apply_appearance(_: &tauri::WebviewWindow, _: bool) {}
