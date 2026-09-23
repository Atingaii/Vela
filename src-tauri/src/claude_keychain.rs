//! Claude Code's borrowed macOS credential. All UI permission and refusal
//! decisions live here; neither the Desktop cache nor the CLI can bypass a
//! person's explicit Deny.

use super::{Credential, Profile};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::{Mutex, OnceLock};

const GRANT_MS: u64 = 60_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ReadError {
    NeedsAuth,
    SignedOut,
    Denied,
    Transient,
}

#[derive(Default, Serialize, Deserialize)]
struct Refusals {
    ids: BTreeSet<String>,
}

#[derive(Default)]
struct PermissionState {
    refused: BTreeSet<String>,
    owed_until: BTreeMap<String, u64>,
    #[cfg(target_os = "macos")]
    cached: BTreeMap<String, (f64, Credential)>,
}

impl PermissionState {
    fn refused(&self, id: &str, now: u64) -> bool {
        self.refused.contains(id) && !self.asking(id, now)
    }

    fn asking(&self, id: &str, now: u64) -> bool {
        self.owed_until.get(id).is_some_and(|until| now < *until)
    }

    fn grant(&mut self, id: &str, now: u64) {
        self.owed_until
            .insert(id.into(), now.saturating_add(GRANT_MS));
        #[cfg(target_os = "macos")]
        self.cached.remove(id);
    }

    fn take(&mut self, id: &str, now: u64) -> bool {
        self.owed_until.remove(id).is_some_and(|until| now < until)
    }
}

static PERMISSIONS: OnceLock<Mutex<PermissionState>> = OnceLock::new();

fn path() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("claude-keychain-refusals.json")
}

fn state() -> &'static Mutex<PermissionState> {
    PERMISSIONS.get_or_init(|| {
        let refusals = std::fs::read(path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Refusals>(&bytes).ok())
            .unwrap_or_default();
        Mutex::new(PermissionState {
            refused: refusals.ids,
            ..Default::default()
        })
    })
}

fn set_refused(id: &str, refused: bool) {
    let mut guard = state().lock().unwrap();
    if refused {
        guard.refused.insert(id.into());
    } else {
        guard.refused.remove(id);
    }
    let bytes = serde_json::to_vec(&Refusals {
        ids: guard.refused.clone(),
    });
    if let Ok(bytes) = bytes {
        let _ = crate::providers::persist(&path(), &bytes);
    }
}

pub(super) fn was_refused(id: &str) -> bool {
    state().lock().unwrap().refused(id, super::now_ms())
}

pub(super) fn asking_again(id: &str) -> bool {
    state().lock().unwrap().asking(id, super::now_ms())
}

pub(super) fn grant(id: &str) {
    state().lock().unwrap().grant(id, super::now_ms());
}

#[cfg(target_os = "macos")]
pub(super) fn has_credential(profile: &Profile) -> bool {
    native::newest(&native::services(profile)).is_some()
}

#[cfg(not(target_os = "macos"))]
pub(super) fn has_credential(profile: &Profile) -> bool {
    [".credentials.json", "credentials.json"]
        .into_iter()
        .any(|name| profile.dir.join(name).is_file())
}

#[cfg(target_os = "macos")]
pub(super) fn forget_cached(id: &str) {
    state().lock().unwrap().cached.remove(id);
}

#[cfg(not(target_os = "macos"))]
pub(super) fn forget_cached(_id: &str) {}

/// Read one exact borrowed item with the same bounded, no-prompt Security
/// path used by Claude. The caller owns its own one-use permission state.
#[cfg(target_os = "macos")]
pub(super) fn borrowed_secret(
    service: &str,
    account: &str,
    interactive: bool,
) -> Result<Option<Vec<u8>>, ReadError> {
    let Some(item) = native::exact(service, account) else {
        return Ok(None);
    };
    native::read_secret(&item, interactive).map(Some)
}

#[cfg(target_os = "macos")]
pub(super) fn has_borrowed_secret(service: &str, account: &str) -> bool {
    native::exact(service, account).is_some()
}

/// The sole one-use source of an interactive keychain read. A timer never
/// passes true merely because a previous refresh happened to be refused.
#[cfg(target_os = "macos")]
pub(super) fn read(profile: &Profile, ask_again: bool) -> Result<Credential, ReadError> {
    let id = super::profile_id(profile);
    let interactive = if ask_again {
        state().lock().unwrap().take(&id, super::now_ms())
    } else {
        false
    };
    if was_refused(&id) && !interactive {
        return Err(ReadError::Denied);
    }
    let services = native::services(profile);
    let newest = native::newest(&services).ok_or(ReadError::NeedsAuth)?;
    if !interactive {
        if let Some((modified, credential)) = state().lock().unwrap().cached.get(&id) {
            if *modified == newest.modified && !credential.expired(super::now_ms()) {
                return Ok(credential.clone());
            }
        }
    }
    match native::read(&newest, interactive) {
        Ok(credential) => {
            if interactive {
                set_refused(&id, false);
            }
            state()
                .lock()
                .unwrap()
                .cached
                .insert(id, (newest.modified, credential.clone()));
            Ok(credential)
        }
        Err(ReadError::Denied) if interactive => {
            set_refused(&id, true);
            Err(ReadError::Denied)
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_grant_is_one_use_and_expires_after_sixty_seconds() {
        let mut state = PermissionState::default();
        state.refused.insert("claude-work".into());
        assert!(state.refused("claude-work", 100));
        state.grant("claude-work", 100);
        assert!(!state.refused("claude-work", 100));
        assert!(state.take("claude-work", 60_099));
        assert!(!state.take("claude-work", 101));
        state.grant("claude-work", 100);
        assert!(!state.take("claude-work", 60_100));
        assert!(state.refused("claude-work", 60_100));
    }
}

#[cfg(target_os = "macos")]
mod native {
    use super::{Credential, Profile, ReadError};
    use core_foundation::array::CFArray;
    use core_foundation::base::{CFType, TCFType, ToVoid};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::data::CFData;
    use core_foundation::date::CFDate;
    use core_foundation::dictionary::{CFDictionary, CFMutableDictionary};
    use core_foundation::string::CFString;
    use security_framework_sys::item::*;
    use security_framework_sys::keychain::{
        SecKeychainGetUserInteractionAllowed, SecKeychainSetUserInteractionAllowed,
    };
    use security_framework_sys::keychain_item::SecItemCopyMatching;
    use sha2::{Digest, Sha256};
    use std::ffi::c_void;
    use std::path::Path;
    use std::process::Command;
    use std::sync::Mutex;
    use std::time::Duration;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecAttrModificationDate: *const c_void;
        static kSecValuePersistentRef: *const c_void;
        static kSecUseAuthenticationUIFail: *const c_void;
    }

    static INTERACTION_LOCK: Mutex<()> = Mutex::new(());

    #[derive(Clone)]
    pub(super) struct Match {
        pub(super) modified: f64,
        service: String,
        account: String,
        reference: Vec<u8>,
    }

    pub(super) fn services(profile: &Profile) -> Vec<String> {
        let path = profile.dir.to_string_lossy();
        let hash = Sha256::digest(path.as_bytes());
        let suffix = hash[..4]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        let mut values = vec![format!("Claude Code-credentials-{suffix}")];
        if profile.slug.is_none() {
            values.push("Claude Code-credentials".into());
        }
        values
    }

    unsafe fn dict_value(dict: &CFDictionary, key: *const c_void) -> Option<CFType> {
        let value = dict.find(key)?;
        Some(CFType::wrap_under_get_rule(*value as _))
    }

    unsafe fn matches(service: &str) -> Vec<Match> {
        let mut query = CFMutableDictionary::from_CFType_pairs(&[]);
        query.add(&kSecClass.to_void(), &kSecClassGenericPassword.to_void());
        query.add(
            &kSecAttrService.to_void(),
            &CFString::new(service).to_void(),
        );
        query.add(
            &kSecReturnAttributes.to_void(),
            &CFBoolean::true_value().to_void(),
        );
        query.add(
            &kSecReturnPersistentRef.to_void(),
            &CFBoolean::true_value().to_void(),
        );
        query.add(&kSecMatchLimit.to_void(), &kSecMatchLimitAll.to_void());
        let mut result = std::ptr::null();
        if SecItemCopyMatching(query.to_immutable().as_concrete_TypeRef(), &mut result) != 0
            || result.is_null()
        {
            return Vec::new();
        }
        let object = CFType::wrap_under_create_rule(result);
        let dictionaries: Vec<CFDictionary> = if let Some(items) = object.downcast::<CFArray>() {
            items
                .iter()
                .filter_map(|item| {
                    CFType::wrap_under_get_rule(*item as _).downcast::<CFDictionary>()
                })
                .collect()
        } else {
            object.downcast::<CFDictionary>().into_iter().collect()
        };
        dictionaries
            .iter()
            .filter_map(|dictionary| {
                let reference = dict_value(dictionary, kSecValuePersistentRef)?
                    .downcast::<CFData>()?
                    .bytes()
                    .to_vec();
                let modified = dict_value(dictionary, kSecAttrModificationDate)?
                    .downcast::<CFDate>()?
                    .abs_time();
                let account = dict_value(dictionary, kSecAttrAccount.to_void())?
                    .downcast::<CFString>()?
                    .to_string();
                Some(Match {
                    modified,
                    service: service.into(),
                    account,
                    reference,
                })
            })
            .collect()
    }

    pub(super) fn newest(services: &[String]) -> Option<Match> {
        services
            .iter()
            .flat_map(|service| unsafe { matches(service) })
            .max_by(|a, b| a.modified.total_cmp(&b.modified))
    }

    fn decode(bytes: &[u8]) -> Result<Credential, ReadError> {
        let value: serde_json::Value =
            serde_json::from_slice(bytes).map_err(|_| ReadError::NeedsAuth)?;
        let oauth = value.get("claudeAiOauth").ok_or(ReadError::NeedsAuth)?;
        let token = oauth
            .get("accessToken")
            .and_then(|value| value.as_str())
            .ok_or(ReadError::NeedsAuth)?;
        if token.is_empty() {
            return Err(ReadError::SignedOut);
        }
        let expires_at = oauth
            .get("expiresAt")
            .and_then(|value| value.as_f64())
            .filter(|value| value.is_finite() && *value >= 0.0)
            .map(|value| value as u64)
            .ok_or(ReadError::NeedsAuth)?;
        Ok(Credential {
            token: token.into(),
            expires_at: Some(expires_at),
            plan: oauth
                .get("subscriptionType")
                .and_then(|value| value.as_str())
                .map(str::to_owned),
        })
    }

    pub(super) fn exact(service: &str, account: &str) -> Option<Match> {
        unsafe { matches(service) }
            .into_iter()
            .filter(|item| item.account == account)
            .max_by(|a, b| a.modified.total_cmp(&b.modified))
    }

    pub(super) fn read(item: &Match, interactive: bool) -> Result<Credential, ReadError> {
        read_secret(item, interactive).and_then(|bytes| decode(&bytes))
    }

    pub(super) fn read_secret(item: &Match, interactive: bool) -> Result<Vec<u8>, ReadError> {
        let _guard = INTERACTION_LOCK.lock().unwrap();
        let mut was_allowed: u8 = 1;
        if !interactive {
            unsafe {
                if SecKeychainGetUserInteractionAllowed(&mut was_allowed) != 0
                    || SecKeychainSetUserInteractionAllowed(0) != 0
                {
                    return Err(ReadError::Transient);
                }
            }
        }
        let mut result = unsafe { read_locked(item, interactive) };
        if !interactive && matches!(result, Err(ReadError::Denied)) {
            if let Some(bytes) = rescue_via_security_tool(&item.service, &item.account) {
                result = Ok(bytes);
            }
        }
        if !interactive {
            unsafe { SecKeychainSetUserInteractionAllowed(was_allowed) };
        }
        result
    }

    /// Claude Code writes through Apple's security tool, which remains on the
    /// borrowed item's partition list. This read is bounded and never runs
    /// after an explicit interactive Deny.
    fn rescue_via_security_tool(service: &str, account: &str) -> Option<Vec<u8>> {
        rescue_via_security_tool_at(
            Path::new("/usr/bin/security"),
            service,
            account,
            Duration::from_secs(3),
        )
    }

    fn rescue_via_security_tool_at(
        tool: &Path,
        service: &str,
        account: &str,
        timeout: Duration,
    ) -> Option<Vec<u8>> {
        let mut command = Command::new(tool);
        command.args(["find-generic-password", "-a", account, "-s", service, "-w"]);
        let mut bytes = super::super::process_output::output(command, 8_192, timeout)?;
        while bytes
            .last()
            .is_some_and(|byte| *byte == b'\n' || *byte == b'\r')
        {
            bytes.pop();
        }
        (!bytes.is_empty()).then_some(bytes)
    }

    unsafe fn read_locked(item: &Match, interactive: bool) -> Result<Vec<u8>, ReadError> {
        let mut query = CFMutableDictionary::from_CFType_pairs(&[]);
        query.add(&kSecClass.to_void(), &kSecClassGenericPassword.to_void());
        query.add(
            &kSecValuePersistentRef,
            &CFData::from_buffer(&item.reference).to_void(),
        );
        query.add(
            &kSecReturnData.to_void(),
            &CFBoolean::true_value().to_void(),
        );
        if !interactive {
            query.add(
                &kSecUseAuthenticationUI.to_void(),
                &kSecUseAuthenticationUIFail,
            );
        }
        let mut result = std::ptr::null();
        let status = SecItemCopyMatching(query.to_immutable().as_concrete_TypeRef(), &mut result);
        match status {
            0 if !result.is_null() => {
                let data = CFType::wrap_under_create_rule(result)
                    .downcast::<CFData>()
                    .ok_or(ReadError::NeedsAuth)?;
                Ok(data.bytes().to_vec())
            }
            -25320 | -60008 => Err(ReadError::Transient),
            -128 | -25293 | -25308 => Err(ReadError::Denied),
            _ => Err(ReadError::NeedsAuth),
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn named_profile_never_uses_default_service() {
            let profile = Profile {
                dir: "/tmp/.claude-work".into(),
                slug: Some("work".into()),
            };
            let names = services(&profile);
            assert_eq!(names.len(), 1);
            assert!(names[0].starts_with("Claude Code-credentials-"));
        }
        #[test]
        fn empty_borrowed_token_is_a_sign_out_not_a_usable_bearer() {
            assert!(matches!(
                decode(br#"{"claudeAiOauth":{"accessToken":"","expiresAt":0}}"#),
                Err(ReadError::SignedOut)
            ));
        }
        #[test]
        fn rescue_reader_kills_a_child_that_closed_stdout_but_keeps_running() {
            use std::os::unix::fs::PermissionsExt;
            use std::time::Instant;
            let temp = tempfile::tempdir().unwrap();
            let script = temp.path().join("security");
            std::fs::write(&script, b"#!/bin/sh\nexec 1>&-\nwhile :; do :; done\n").unwrap();
            let mut permissions = std::fs::metadata(&script).unwrap().permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&script, permissions).unwrap();
            let start = Instant::now();
            assert!(rescue_via_security_tool_at(
                &script,
                "Claude Code-credentials-fixture",
                "fixture",
                Duration::from_millis(250),
            )
            .is_none());
            assert!(start.elapsed() < Duration::from_secs(2));
        }
    }
}
