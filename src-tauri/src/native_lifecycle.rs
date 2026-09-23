//! macOS application lifecycle events that do not arrive through Tauri's window events.

use std::{cell::RefCell, ptr::NonNull, time::Duration};

use block2::RcBlock;
use objc2::{rc::Retained, runtime::ProtocolObject};
use objc2_app_kit::{NSRunningApplication, NSWorkspace, NSWorkspaceDidWakeNotification};
use objc2_foundation::{NSBundle, NSNotification, NSObjectProtocol, NSOperationQueue, NSString};
use tauri::AppHandle;

type WakeToken = Retained<ProtocolObject<dyn NSObjectProtocol>>;

thread_local! {
    // Registered and removed on the AppKit thread, just like UsageStore's Swift observer.
    static WAKE_OBSERVER: RefCell<Option<WakeToken>> =
        const { RefCell::new(None) };
}

fn register_wake_block(block: &block2::DynBlock<dyn Fn(NonNull<NSNotification>)>) -> WakeToken {
    // SAFETY: the notification name belongs to AppKit; callers keep the returned token and
    // remove it on the same AppKit thread. Delivery is explicitly on the main queue.
    unsafe {
        NSWorkspace::sharedWorkspace()
            .notificationCenter()
            .addObserverForName_object_queue_usingBlock(
                Some(NSWorkspaceDidWakeNotification),
                None,
                Some(&NSOperationQueue::mainQueue()),
                block,
            )
    }
}

fn unregister_wake_token(token: WakeToken) {
    // SAFETY: this is the exact opaque observer token returned by the same center.
    let token_ref: &ProtocolObject<dyn NSObjectProtocol> = &token;
    let object: &objc2::runtime::AnyObject = <ProtocolObject<dyn NSObjectProtocol> as AsRef<
        objc2::runtime::AnyObject,
    >>::as_ref(token_ref);
    unsafe {
        NSWorkspace::sharedWorkspace()
            .notificationCenter()
            .removeObserver(object)
    };
}

/// Called only by the isolated native installation smoke on the AppKit thread. This exercises
/// the production registration/removal pair without posting a system notification or reading an
/// account. The Objective-C API returns a non-null token rather than a Result.
pub fn probe_wake_subscription() -> bool {
    let callback = RcBlock::new(|_notification: NonNull<NSNotification>| {});
    unregister_wake_token(register_wake_block(&callback));
    true
}

pub fn start_wake_watch(app: AppHandle) {
    WAKE_OBSERVER.with(|slot| {
        if slot.borrow().is_some() {
            return;
        }
        let callback = RcBlock::new(move |_notification: NonNull<NSNotification>| {
            let app = app.clone();
            // Refresh All only queues each enabled provider's existing scheduler. Keep the
            // Workspace notification and the AppKit thread free of account discovery work.
            let _ = std::thread::Builder::new()
                .name("velo-wake-refresh".into())
                .spawn(move || {
                    let _ = crate::refresh_all_tracked(&app);
                });
        });
        let token = register_wake_block(&callback);
        *slot.borrow_mut() = Some(token);
    });
}

pub fn stop_wake_watch() {
    WAKE_OBSERVER.with(|slot| {
        if let Some(token) = slot.borrow_mut().take() {
            unregister_wake_token(token);
        }
    });
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ProcessIdentity {
    uid: libc::uid_t,
    started_sec: u64,
    started_usec: u64,
}

fn process_identity(pid: i32) -> Option<ProcessIdentity> {
    if pid <= 0 {
        return None;
    }
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>();
    let read = unsafe {
        libc::proc_pidinfo(
            pid,
            libc::PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut _,
            size as i32,
        )
    };
    (read == size as i32
        && info.pbi_pid == pid as u32
        && info.pbi_start_tvsec > 0
        && info.pbi_start_tvusec < 1_000_000)
        .then_some(ProcessIdentity {
            uid: info.pbi_uid,
            started_sec: info.pbi_start_tvsec,
            started_usec: info.pbi_start_tvusec,
        })
}

fn should_retire(
    current_bundle: &str,
    candidate_bundle: &str,
    current_executable: &str,
    candidate_executable: &str,
    current_identity: ProcessIdentity,
    candidate_identity: ProcessIdentity,
    same_pid: bool,
) -> bool {
    !same_pid
        && !current_bundle.is_empty()
        && current_bundle == candidate_bundle
        && !current_executable.is_empty()
        && current_executable == candidate_executable
        && current_identity.uid == candidate_identity.uid
        && (
            candidate_identity.started_sec,
            candidate_identity.started_usec,
        ) < (current_identity.started_sec, current_identity.started_usec)
}

/// Swift's newcomer-wins rule, narrowed to a positively identified same-user application.
/// No path or version ordering is involved: separate installation paths are precisely the case
/// where the older copy must retire. LaunchServices may omit NSRunningApplication.launchDate for
/// a bundle executable started directly, so compare verified kernel birth timestamps instead.
/// Unknown bundle, executable or owner is skipped.
pub fn retire_older_instances() {
    let Some(bundle) = NSBundle::mainBundle()
        .bundleIdentifier()
        .map(|value| value.to_string())
    else {
        return;
    };
    let Some(executable) = std::env::current_exe()
        .ok()
        .and_then(|path| path.file_name().map(|name| name.to_owned()))
        .and_then(|name| name.into_string().ok())
    else {
        return;
    };
    let Ok(current_pid) = i32::try_from(std::process::id()) else {
        return;
    };
    let Some(current_identity) = process_identity(current_pid) else {
        return;
    };
    if current_identity.uid != unsafe { libc::getuid() } {
        return;
    }

    for other in
        NSRunningApplication::runningApplicationsWithBundleIdentifier(&NSString::from_str(&bundle))
            .iter()
    {
        let pid = other.processIdentifier();
        let Some(identity) = process_identity(pid) else {
            continue;
        };
        let Some(other_bundle) = other.bundleIdentifier().map(|value| value.to_string()) else {
            continue;
        };
        let Some(other_executable) = other
            .executableURL()
            .and_then(|url| url.lastPathComponent())
            .map(|value| value.to_string())
        else {
            continue;
        };
        if !should_retire(
            &bundle,
            &other_bundle,
            &executable,
            &other_executable,
            current_identity,
            identity,
            pid == current_pid,
        ) {
            continue;
        }
        // Re-check both LaunchServices and the kernel process birth immediately before sending
        // an exit request. A recycled PID must never receive a signal intended for the old app.
        let Some(live) =
            (unsafe { NSRunningApplication::runningApplicationWithProcessIdentifier(pid) })
        else {
            continue;
        };
        if process_identity(pid) != Some(identity)
            || live
                .bundleIdentifier()
                .map(|value| value.to_string())
                .as_deref()
                != Some(bundle.as_str())
            || live
                .executableURL()
                .and_then(|url| url.lastPathComponent())
                .map(|value| value.to_string())
                .as_deref()
                != Some(executable.as_str())
        {
            continue;
        }
        crate::applog(&format!("retiring older Velo instance pid={pid}"));
        if !live.terminate() {
            let _ = live.forceTerminate();
        }
        // terminate() is asynchronous. Give the old window and local listeners a brief chance
        // to go away before the new notch is created, without blocking launch indefinitely.
        for _ in 0..80 {
            if live.isTerminated() {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{should_retire, ProcessIdentity};

    #[test]
    fn takeover_needs_older_kernel_birth_same_bundle_executable_and_user() {
        let candidate = |bundle, executable, uid, birth_sec, birth_usec, same_pid| {
            should_retire(
                "com.atingaii.vela",
                bundle,
                "vela",
                executable,
                ProcessIdentity {
                    uid: 501,
                    started_sec: 200,
                    started_usec: 500,
                },
                ProcessIdentity {
                    uid,
                    started_sec: birth_sec,
                    started_usec: birth_usec,
                },
                same_pid,
            )
        };
        assert!(candidate("com.atingaii.vela", "vela", 501, 100, 0, false));
        assert!(candidate("com.atingaii.vela", "vela", 501, 200, 499, false));
        assert!(!candidate(
            "com.atingaii.codenotch",
            "vela",
            501,
            100,
            0,
            false
        ));
        assert!(!candidate(
            "com.atingaii.vela",
            "unrelated",
            501,
            100,
            0,
            false
        ));
        assert!(!candidate("com.atingaii.vela", "vela", 502, 100, 0, false));
        assert!(!candidate(
            "com.atingaii.vela",
            "vela",
            501,
            200,
            500,
            false
        ));
        assert!(!candidate(
            "com.atingaii.vela",
            "vela",
            501,
            200,
            501,
            false
        ));
        assert!(!candidate("com.atingaii.vela", "vela", 501, 201, 0, false));
        assert!(!candidate("com.atingaii.vela", "vela", 501, 100, 0, true));
    }
}
