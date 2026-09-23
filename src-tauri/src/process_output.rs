//! Bounded output for helper processes owned by this app. A shell/npm shim can
//! exit while its child still holds stdout open, so an EOF-based reader alone
//! is never a timeout.

use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn terminate_tree(child: &mut Child) {
    #[cfg(unix)]
    unsafe {
        // Every command passed to output() starts a new process group. Never
        // signal the launcher's or a user's existing CLI process group.
        let _ = libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    #[cfg(windows)]
    {
        // The caller drops its Job Object first, killing the whole assigned
        // tree. If job assignment failed, still reap the direct child.
    }
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(windows)]
struct OwnedJob(windows::Win32::Foundation::HANDLE);

#[cfg(windows)]
impl OwnedJob {
    fn attach(child: &Child) -> Option<Self> {
        use std::os::windows::io::AsRawHandle;
        use windows::Win32::{
            Foundation::HANDLE,
            System::JobObjects::{
                AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation,
                SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
                JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
            },
        };
        let job = Self(unsafe { CreateJobObjectW(None, windows::core::PCWSTR::null()).ok()? });
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as *const std::ffi::c_void,
                std::mem::size_of_val(&limits) as u32,
            )
            .ok()?;
            AssignProcessToJobObject(job.0, HANDLE(child.as_raw_handle())).ok()?;
        }
        Some(job)
    }
}

#[cfg(windows)]
fn resume_suspended_child(child: &Child) -> Option<()> {
    use windows::Win32::{
        Foundation::CloseHandle,
        System::{
            Diagnostics::ToolHelp::{
                CreateToolhelp32Snapshot, Thread32First, Thread32Next, TH32CS_SNAPTHREAD,
                THREADENTRY32,
            },
            Threading::{OpenThread, ResumeThread, THREAD_SUSPEND_RESUME},
        },
    };
    let snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0).ok()? };
    let mut entry = THREADENTRY32::default();
    entry.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
    let mut found = false;
    let mut current = unsafe { Thread32First(snapshot, &mut entry).is_ok() };
    while current {
        if entry.th32OwnerProcessID == child.id() {
            if let Ok(thread) =
                unsafe { OpenThread(THREAD_SUSPEND_RESUME, false, entry.th32ThreadID) }
            {
                let count = unsafe { ResumeThread(thread) };
                let _ = unsafe { CloseHandle(thread) };
                if count == u32::MAX {
                    break;
                }
                found = true;
                break;
            }
        }
        current = unsafe { Thread32Next(snapshot, &mut entry).is_ok() };
    }
    let _ = unsafe { CloseHandle(snapshot) };
    found.then_some(())
}

#[cfg(windows)]
impl Drop for OwnedJob {
    fn drop(&mut self) {
        // Every descendant assigned to this app-owned job dies even when the
        // direct child has already exited and left a pipe handle in a shim.
        let _ = unsafe { windows::Win32::Foundation::CloseHandle(self.0) };
    }
}

/// Kiro needs the exit status to distinguish a CLI sign-out from a transient
/// process failure. Bytes from a failed process may be partial; Kiro ignores
/// them. Other callers keep output()'s existing success-only API.
#[cfg(unix)]
pub(crate) fn output_with_status(
    mut command: Command,
    max: usize,
    timeout: Duration,
) -> Option<(std::process::ExitStatus, Vec<u8>)> {
    use std::os::unix::process::CommandExt;
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    let mut child = command.spawn().ok()?;
    let Some(stdout) = child.stdout.take() else {
        terminate_tree(&mut child);
        return None;
    };
    let outcome = read_unix(&mut child, stdout, max, timeout);
    terminate_tree(&mut child);
    outcome
}

pub(crate) fn output(command: Command, max: usize, timeout: Duration) -> Option<Vec<u8>> {
    #[cfg(unix)]
    {
        return output_with_status(command, max, timeout)
            .and_then(|(status, bytes)| status.success().then_some(bytes));
    }
    #[cfg(not(unix))]
    {
        let mut command = command;
        command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            // Stop the main thread before it executes user code. Assign its
            // process to our Job Object, then resume only that child's thread.
            command.creation_flags(0x0800_0000 | 0x0000_0200 | 0x0000_0004);
        }
        let mut child = command.spawn().ok()?;
        let Some(stdout) = child.stdout.take() else {
            terminate_tree(&mut child);
            return None;
        };
        #[cfg(windows)]
        let Some(job) = OwnedJob::attach(&child) else {
            terminate_tree(&mut child);
            return None;
        };
        #[cfg(windows)]
        if resume_suspended_child(&child).is_none() {
            drop(job);
            terminate_tree(&mut child);
            return None;
        }
        #[cfg(windows)]
        let outcome = read_windows(&mut child, stdout, max, timeout);
        #[cfg(not(windows))]
        let outcome: Option<Vec<u8>> = None;
        #[cfg(windows)]
        drop(job);
        terminate_tree(&mut child);
        outcome
    }
}

#[cfg(unix)]
fn read_unix(
    child: &mut Child,
    mut stdout: std::process::ChildStdout,
    max: usize,
    timeout: Duration,
) -> Option<(std::process::ExitStatus, Vec<u8>)> {
    use std::os::fd::AsRawFd;
    let fd = stdout.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return None;
    }
    let deadline = Instant::now() + timeout;
    let mut bytes = Vec::new();
    let mut eof = false;
    loop {
        let mut chunk = [0u8; 8192];
        match stdout.read(&mut chunk) {
            Ok(0) => eof = true,
            Ok(n) => {
                if bytes.len().saturating_add(n) > max {
                    return None;
                }
                bytes.extend_from_slice(&chunk[..n]);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return None,
        }
        let status = child.try_wait().ok()?;
        if let Some(status) = status {
            // A failed CLI does not need to wait for a descendant that still
            // holds stdout; its status is already authoritative.
            if !status.success() || eof {
                return Some((status, bytes));
            }
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(windows)]
fn read_windows(
    child: &mut Child,
    mut stdout: std::process::ChildStdout,
    max: usize,
    timeout: Duration,
) -> Option<Vec<u8>> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::{Foundation::HANDLE, System::Pipes::PeekNamedPipe};
    let pipe = HANDLE(stdout.as_raw_handle());
    let deadline = Instant::now() + timeout;
    let mut bytes = Vec::new();
    let mut eof = false;
    loop {
        let mut available = 0u32;
        if unsafe { PeekNamedPipe(pipe, None, 0, None, Some(&mut available), None) }.is_err() {
            eof = true;
        } else if available > 0 {
            let mut chunk = [0u8; 8192];
            let size = (available as usize).min(chunk.len());
            let n = stdout.read(&mut chunk[..size]).ok()?;
            if n == 0 {
                eof = true;
            } else {
                if bytes.len().saturating_add(n) > max {
                    return None;
                }
                bytes.extend_from_slice(&chunk[..n]);
            }
        }
        if eof {
            if let Some(status) = child.try_wait().ok()? {
                return status.success().then_some(bytes);
            }
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn forked_child_holding_stdout_cannot_extend_the_deadline() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let script = temp.path().join("helper");
        std::fs::write(&script, b"#!/bin/sh\n(sleep 10) &\nexit 0\n").unwrap();
        let mut permissions = std::fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&script, permissions).unwrap();
        let started = Instant::now();
        assert!(output(Command::new(&script), 1024, Duration::from_millis(250)).is_none());
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[cfg(unix)]
    #[test]
    fn status_interface_preserves_exit_failure_without_changing_output_contract() {
        use std::os::unix::fs::PermissionsExt;
        let temp = tempfile::tempdir().unwrap();
        let script = temp.path().join("helper");
        std::fs::write(&script, b"#!/bin/sh\nprintf 'not signed in\\n'\nexit 7\n").unwrap();
        let mut permissions = std::fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&script, permissions).unwrap();
        let (status, _bytes) =
            output_with_status(Command::new(&script), 1024, Duration::from_secs(2)).unwrap();
        assert_eq!(status.code(), Some(7));
        assert!(output(Command::new(&script), 1024, Duration::from_secs(2)).is_none());
    }

    #[cfg(windows)]
    #[test]
    fn fast_shim_descendant_holding_stdout_cannot_extend_the_deadline() {
        const MODE: &str = "VELO_TEST_OUTPUT_SHIM_MODE";
        const MARKER: &str = "VELO_TEST_OUTPUT_SHIM_MARKER";
        let exe = std::env::current_exe().unwrap();
        let (_, module) = module_path!().split_once("::").unwrap();
        let own_test =
            format!("{module}::fast_shim_descendant_holding_stdout_cannot_extend_the_deadline");
        match std::env::var(MODE).as_deref() {
            Ok("shim") => {
                let marker = std::env::var(MARKER).unwrap();
                std::fs::write(format!("{marker}.shim"), b"started").unwrap();
                // The grandchild inherits stdout and outlives this helper.
                let _ = Command::new(&exe)
                    .args(["--exact", &own_test])
                    .env(MODE, "grandchild")
                    .stdout(Stdio::inherit())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap();
                return;
            }
            Ok("grandchild") => {
                let marker = std::env::var(MARKER).unwrap();
                std::fs::write(format!("{marker}.grandchild"), b"started").unwrap();
                std::thread::sleep(Duration::from_secs(10));
                return;
            }
            _ => {}
        }
        let temp = tempfile::tempdir().unwrap();
        let marker = temp.path().join("ran");
        let started = Instant::now();
        assert!(output(
            {
                let mut command = Command::new(&exe);
                command
                    .args(["--exact", &own_test])
                    .env(MODE, "shim")
                    .env(MARKER, &marker);
                command
            },
            4096,
            Duration::from_millis(500)
        )
        .is_none());
        assert!(started.elapsed() < Duration::from_secs(2));
        let shim = format!("{}.shim", marker.display());
        let grandchild = format!("{}.grandchild", marker.display());
        assert!(
            std::path::Path::new(&shim).is_file(),
            "shim test did not execute"
        );
        assert!(
            std::path::Path::new(&grandchild).is_file(),
            "descendant test did not execute"
        );
    }
}
