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

#[cfg(not(target_os = "macos"))]
pub fn configure(_: &tauri::WebviewWindow) {}
