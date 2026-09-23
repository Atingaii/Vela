//! Windows power notifications corresponding to UsageStore's macOS wake observer.

use std::{
    cell::RefCell,
    ffi::c_void,
    sync::{
        atomic::{AtomicBool, Ordering},
        OnceLock,
    },
};

use tauri::AppHandle;
use windows::Win32::{
    Foundation::HANDLE,
    System::Power::{
        RegisterSuspendResumeNotification, UnregisterSuspendResumeNotification,
        DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS, HPOWERNOTIFY, PDEVICE_NOTIFY_CALLBACK_ROUTINE,
    },
    UI::WindowsAndMessaging::{DEVICE_NOTIFY_CALLBACK, PBT_APMRESUMEAUTOMATIC},
};

static WAKE_APP: OnceLock<AppHandle> = OnceLock::new();
static WAKE_ACTIVE: AtomicBool = AtomicBool::new(false);

thread_local! {
    // Registration and unregistration run on the Tauri event-loop thread. Retaining the
    // parameters keeps the native recipient address stable for the entire subscription.
    static SUBSCRIPTION: RefCell<Option<Subscription>> =
        const { RefCell::new(None) };
}

struct Subscription {
    handle: HPOWERNOTIFY,
    params: Box<DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS>,
}

fn register_wake_callback(
    callback: PDEVICE_NOTIFY_CALLBACK_ROUTINE,
) -> Result<Subscription, String> {
    let params = Box::new(DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
        Callback: callback,
        Context: std::ptr::null_mut(),
    });
    let recipient = HANDLE(
        (&*params as *const DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS)
            .cast_mut()
            .cast(),
    );
    // SAFETY: recipient points to retained callback parameters, which remain alive until
    // UnregisterSuspendResumeNotification. The callback does not dereference Context.
    let handle = unsafe { RegisterSuspendResumeNotification(recipient, DEVICE_NOTIFY_CALLBACK) }
        .map_err(|error| error.to_string())?;
    Ok(Subscription { handle, params })
}

fn unregister_wake_callback(subscription: Subscription) -> Result<(), String> {
    // SAFETY: this is the handle returned for our own registration.
    if let Err(error) = unsafe { UnregisterSuspendResumeNotification(subscription.handle) } {
        // An unsuccessful unregister can leave the callback active. Keep the recipient address
        // alive until process exit; WAKE_ACTIVE blocks further production work.
        std::mem::forget(subscription.params);
        return Err(error.to_string());
    }
    Ok(())
}

/// Called only by the isolated installed-app smoke. No power event is sent, and this callback
/// never accesses an account, even if the system happens to wake during the short registration.
pub fn probe_wake_subscription() -> bool {
    unsafe extern "system" fn noop(
        _context: *const c_void,
        _kind: u32,
        _setting: *const c_void,
    ) -> u32 {
        0
    }
    register_wake_callback(Some(noop))
        .and_then(unregister_wake_callback)
        .is_ok()
}

fn is_resume_event(kind: u32) -> bool {
    // Windows sends PBT_APMRESUMESUSPEND after this event when a user is present. Handling only
    // AUTOMATIC refreshes once for both attended and unattended resume.
    kind == PBT_APMRESUMEAUTOMATIC
}

unsafe extern "system" fn power_event(
    _context: *const c_void,
    kind: u32,
    _setting: *const c_void,
) -> u32 {
    if is_resume_event(kind) && WAKE_ACTIVE.load(Ordering::Acquire) {
        if let Some(app) = WAKE_APP.get() {
            let app = app.clone();
            // The power callback is time-limited. It must only queue work, never read accounts
            // or wait for a provider on the notification thread.
            let _ = std::thread::Builder::new()
                .name("velo-wake-refresh".into())
                .spawn(move || {
                    let _ = crate::refresh_all_tracked(&app);
                });
        }
    }
    0 // ERROR_SUCCESS
}

pub fn start_wake_watch(app: AppHandle) {
    SUBSCRIPTION.with(|slot| {
        if slot.borrow().is_some() {
            return;
        }
        let _ = WAKE_APP.set(app);
        match register_wake_callback(Some(power_event)) {
            Ok(subscription) => {
                *slot.borrow_mut() = Some(subscription);
                WAKE_ACTIVE.store(true, Ordering::Release);
            }
            Err(error) => crate::applog(&format!("Windows wake subscription: {error}")),
        }
    });
}

pub fn stop_wake_watch() {
    WAKE_ACTIVE.store(false, Ordering::Release);
    SUBSCRIPTION.with(|slot| {
        if let Some(subscription) = slot.borrow_mut().take() {
            if let Err(error) = unregister_wake_callback(subscription) {
                crate::applog(&format!("Windows wake unsubscription: {error}"));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows::Win32::UI::WindowsAndMessaging::{PBT_APMRESUMESUSPEND, PBT_APMSUSPEND};

    #[test]
    fn attended_resume_queues_one_refresh_at_automatic_event() {
        assert!(is_resume_event(PBT_APMRESUMEAUTOMATIC));
        assert!(!is_resume_event(PBT_APMRESUMESUSPEND));
        assert!(!is_resume_event(PBT_APMSUSPEND));
    }
}
