//! Foreground geometry only: no window titles, screen images or accessibility permission.
//! Coordinates are Quartz points on macOS and physical desktop pixels on Windows.
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Mutex,
};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}
impl Rect {
    pub fn intersection(self, other: Self) -> f64 {
        ((self.x + self.w).min(other.x + other.w) - self.x.max(other.x)).max(0.0)
            * ((self.y + self.h).min(other.y + other.h) - self.y.max(other.y)).max(0.0)
    }
    pub fn covers(self, screen: Self, mac_menu_inset: bool) -> bool {
        const E: f64 = 4.0;
        if self.w <= 0.0
            || self.h <= 0.0
            || (self.x - screen.x).abs() > E
            || (self.w - screen.w).abs() > E
        {
            return false;
        }
        if (self.y - screen.y).abs() <= E && (self.h - screen.h).abs() <= E {
            return true;
        }
        // Swift FullScreenDetector allows the menu/notch inset on macOS. Windows' work-area
        // maximization must not match: its taskbar is not a full-screen application's inset.
        mac_menu_inset
            && self.y >= screen.y - E
            && self.y <= screen.y + 44.0
            && (self.y + self.h - screen.y - screen.h).abs() <= E
            && self.h >= screen.h - 54.0
    }
}
static SELECTED: Mutex<Option<Rect>> = Mutex::new(None);
static FULLSCREEN: AtomicBool = AtomicBool::new(false);
pub fn selected() -> Option<Rect> {
    *SELECTED.lock().unwrap()
}
pub fn fullscreen() -> bool {
    FULLSCREEN.load(Ordering::Relaxed)
}
pub fn set_fullscreen(value: bool) -> bool {
    FULLSCREEN.swap(value, Ordering::Relaxed) != value
}

pub fn screen_rect(s: &crate::Screen) -> Rect {
    let scale = if cfg!(target_os = "macos") {
        s.scale.max(0.1)
    } else {
        1.0
    };
    Rect {
        x: s.x as f64 / scale,
        y: s.y as f64 / scale,
        w: s.w as f64 / scale,
        h: s.h as f64 / scale,
    }
}
pub fn sample() -> Vec<Rect> {
    let windows = native_windows();
    if let Some(r) = windows.first() {
        *SELECTED.lock().unwrap() = Some(*r);
    }
    windows
}

#[cfg(target_os = "windows")]
fn native_windows() -> Vec<Rect> {
    use windows::Win32::{
        Foundation::RECT,
        UI::WindowsAndMessaging::{
            GetForegroundWindow, GetShellWindow, GetWindowRect, GetWindowThreadProcessId, IsIconic,
        },
    };
    unsafe {
        let window = GetForegroundWindow();
        if window.0.is_null() || window == GetShellWindow() || IsIconic(window).as_bool() {
            return Vec::new();
        }
        let mut pid = 0;
        GetWindowThreadProcessId(window, Some(&mut pid));
        if pid == std::process::id() {
            return Vec::new();
        }
        let mut r = RECT::default();
        if GetWindowRect(window, &mut r).is_err() {
            return Vec::new();
        }
        vec![Rect {
            x: r.left as f64,
            y: r.top as f64,
            w: (r.right - r.left) as f64,
            h: (r.bottom - r.top) as f64,
        }]
    }
}
#[cfg(target_os = "macos")]
fn native_windows() -> Vec<Rect> {
    use std::ffi::c_void;
    type CFRef = *const c_void;
    #[repr(C)]
    struct Point {
        x: f64,
        y: f64,
    }
    #[repr(C)]
    struct Size {
        w: f64,
        h: f64,
    }
    #[repr(C)]
    struct Bounds {
        origin: Point,
        size: Size,
    }
    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGWindowListCopyWindowInfo(options: u32, relative: u32) -> CFRef;
        fn CGRectMakeWithDictionaryRepresentation(dict: CFRef, rect: *mut Bounds) -> bool;
        static kCGWindowOwnerPID: CFRef;
        static kCGWindowLayer: CFRef;
        static kCGWindowBounds: CFRef;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFArrayGetCount(array: CFRef) -> isize;
        fn CFArrayGetValueAtIndex(array: CFRef, index: isize) -> CFRef;
        fn CFDictionaryGetValue(dict: CFRef, key: CFRef) -> CFRef;
        fn CFNumberGetValue(number: CFRef, kind: isize, out: *mut i32) -> bool;
        fn CFRelease(value: CFRef);
    }
    unsafe {
        let Some(app) = objc2_app_kit::NSWorkspace::sharedWorkspace().frontmostApplication() else {
            return Vec::new();
        };
        let pid = app.processIdentifier();
        if pid as u32 == std::process::id() {
            return Vec::new();
        }
        let array = CGWindowListCopyWindowInfo(1 | 16, 0);
        if array.is_null() {
            return Vec::new();
        }
        let mut out = Vec::new();
        for i in 0..CFArrayGetCount(array) {
            let dict = CFArrayGetValueAtIndex(array, i);
            let owner = CFDictionaryGetValue(dict, kCGWindowOwnerPID);
            let layer = CFDictionaryGetValue(dict, kCGWindowLayer);
            let mut owner_value = 0;
            let mut layer_value = -1;
            if owner.is_null()
                || layer.is_null()
                || !CFNumberGetValue(owner, 3, &mut owner_value)
                || !CFNumberGetValue(layer, 3, &mut layer_value)
                || owner_value != pid
                || layer_value != 0
            {
                continue;
            }
            let bounds = CFDictionaryGetValue(dict, kCGWindowBounds);
            let mut r = Bounds {
                origin: Point { x: 0., y: 0. },
                size: Size { w: 0., h: 0. },
            };
            if !bounds.is_null()
                && CGRectMakeWithDictionaryRepresentation(bounds, &mut r)
                && r.size.w > 0.
                && r.size.h > 0.
            {
                out.push(Rect {
                    x: r.origin.x,
                    y: r.origin.y,
                    w: r.size.w,
                    h: r.size.h,
                });
            }
        }
        CFRelease(array);
        out
    }
}
#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn native_windows() -> Vec<Rect> {
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fullscreen_distinguishes_taskbar_maximize_and_macos_menu_inset() {
        let s = Rect {
            x: -1920.,
            y: 0.,
            w: 1920.,
            h: 1080.,
        };
        assert!(s.covers(s, false));
        assert!(!Rect { h: 1040., ..s }.covers(s, false));
        let menu = Rect {
            y: 32.,
            h: 1048.,
            ..s
        };
        assert!(menu.covers(s, true));
        assert!(!menu.covers(s, false));
        assert!(!Rect { x: 0., ..s }.covers(s, true));
        assert!(!Rect { w: 1910., ..s }.covers(s, true));
    }
    #[test]
    fn screen_choice_uses_overlap_with_negative_desktop_coordinates() {
        let left = Rect {
            x: -1920.,
            y: -100.,
            w: 1920.,
            h: 1080.,
        };
        let right = Rect {
            x: 0.,
            y: 0.,
            w: 2560.,
            h: 1440.,
        };
        let window = Rect {
            x: -700.,
            y: 10.,
            w: 900.,
            h: 800.,
        };
        assert!(window.intersection(left) > window.intersection(right));
        assert_eq!(Rect { x: 4000., ..window }.intersection(right), 0.);
    }
}
