//! A verified updater download waiting for the next launch.
//!
//! Tauri's Windows `Update::install` exits the process after starting NSIS. Keeping the
//! downloaded package here lets an automatic check finish without interrupting a session.
//! Cache files are not trusted: every launch checks the current feed and re-verifies the
//! exact bytes and the version in the minisign trusted comment before handing them to Tauri.

use base64::Engine;
use minisign_verify::{PublicKey, Signature};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

pub const MAX_PACKAGE_BYTES: usize = 512 * 1024 * 1024;
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stage {
    pub version: String,
    pub signature: String,
    pub url: String,
    pub target: String,
    pub consent_generation: u64,
    pub sha256: String,
    pub filename: String,
}

pub fn directory() -> PathBuf {
    crate::config::config_path()
        .parent()
        .expect("config path has a parent")
        .join("updater-stage")
}

fn metadata_path(dir: &Path) -> PathBuf {
    dir.join("stage.json")
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn valid_package_filename(name: &str) -> bool {
    name.len() == "package-".len() + 64 + ".bin".len()
        && name.starts_with("package-")
        && name.ends_with(".bin")
        && name["package-".len()..name.len() - ".bin".len()]
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
}

pub fn read_in(dir: &Path) -> Option<Stage> {
    let metadata_file = std::fs::File::open(metadata_path(dir)).ok()?;
    if metadata_file.metadata().ok()?.len() > 64 * 1024 {
        return None;
    }
    let mut metadata = Vec::new();
    metadata_file.take(64 * 1024 + 1).read_to_end(&mut metadata).ok()?;
    let stage: Stage = serde_json::from_slice(&metadata).ok()?;
    valid_package_filename(&stage.filename).then_some(stage)
}

pub fn read() -> Option<Stage> {
    read_in(&directory())
}

/// Commit metadata last. An interrupted write can leave an orphaned package, but never a
/// metadata record referring to partially written bytes.
pub fn write_in(dir: &Path, stage: &mut Stage, bytes: &[u8]) -> Result<(), String> {
    if bytes.is_empty() || bytes.len() > MAX_PACKAGE_BYTES {
        return Err("Updater package exceeds the allowed size".into());
    }
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    stage.sha256 = digest(bytes);
    stage.filename = format!("package-{}.bin", stage.sha256);
    let mut package = tempfile::NamedTempFile::new_in(dir).map_err(|e| e.to_string())?;
    package.write_all(bytes)
        .and_then(|_| package.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    // Windows rename does not replace an existing destination. Losing the old cache file
    // before metadata commit is safe: the next launch treats a missing package as invalid.
    let _ = std::fs::remove_file(dir.join(&stage.filename));
    package.persist(dir.join(&stage.filename)).map_err(|e| e.error.to_string())?;

    let mut metadata = tempfile::NamedTempFile::new_in(dir).map_err(|e| e.to_string())?;
    let serialized = serde_json::to_vec(stage).map_err(|e| e.to_string())?;
    metadata.write_all(&serialized)
        .and_then(|_| metadata.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    // On Windows a rename cannot replace the existing metadata file. An interrupted replace
    // simply leaves no stage record; it must never expose a partially written record.
    let _ = std::fs::remove_file(metadata_path(dir));
    metadata.persist(metadata_path(dir)).map_err(|e| e.error.to_string())?;
    Ok(())
}

pub fn clear_in(dir: &Path) {
    let previous = read_in(dir);
    let _ = std::fs::remove_file(metadata_path(dir));
    if let Some(previous) = previous {
        let _ = std::fs::remove_file(dir.join(previous.filename));
    }
}

pub fn clear() {
    clear_in(&directory());
}

pub fn read_verified_in(dir: &Path, stage: &Stage, pubkey: &str) -> Result<Vec<u8>, String> {
    if !valid_package_filename(&stage.filename) {
        return Err("Invalid staged package path".into());
    }
    let file = std::fs::File::open(dir.join(&stage.filename)).map_err(|e| e.to_string())?;
    let len = file.metadata().map_err(|e| e.to_string())?.len();
    if len == 0 || len > MAX_PACKAGE_BYTES as u64 {
        return Err("Invalid staged package size".into());
    }
    let mut bytes = Vec::with_capacity(len as usize);
    file.take(MAX_PACKAGE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() != len as usize || digest(&bytes) != stage.sha256 {
        return Err("Staged package changed after download".into());
    }
    verify_signature(&bytes, &stage.signature, pubkey, &stage.version)?;
    Ok(bytes)
}

fn read_limited(
    mut reader: impl Read, expected: Option<usize>, deadline: Instant,
) -> Result<Vec<u8>, String> {
    if expected.is_some_and(|length| length > MAX_PACKAGE_BYTES) {
        return Err("Updater package exceeds the allowed size".into());
    }
    let mut bytes = Vec::with_capacity(expected.unwrap_or(0).min(MAX_PACKAGE_BYTES));
    let mut chunk = [0u8; 64 * 1024];
    loop {
        if Instant::now() >= deadline {
            return Err("The update download timed out".into());
        }
        let read = reader.read(&mut chunk).map_err(|e| e.to_string())?;
        if read == 0 { break; }
        if bytes.len() > MAX_PACKAGE_BYTES - read {
            return Err("Updater package exceeds the allowed size".into());
        }
        bytes.extend_from_slice(&chunk[..read]);
    }
    if bytes.is_empty() || expected.is_some_and(|length| length != bytes.len()) {
        return Err("Updater package was truncated".into());
    }
    Ok(bytes)
}

/// Stream the release asset with both a total clock deadline and a hard byte ceiling. Tauri's
/// `Update::download` checks the signature but buffers without a size ceiling; this uses the
/// same minisign rule below and still delegates installation to Tauri. Redirects are resolved
/// explicitly so a Release CDN hop cannot silently downgrade to HTTP.
pub fn download_verified(app: &AppHandle, update: &tauri_plugin_updater::Update) -> Result<Vec<u8>, String> {
    let deadline = Instant::now() + DOWNLOAD_TIMEOUT;
    let mut url = update.download_url.clone();
    for _ in 0..=5 {
        if url.scheme() != "https" {
            return Err("Updater download requires HTTPS".into());
        }
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() { return Err("The update download timed out".into()); }
        let agent = ureq::builder()
            .redirects(0)
            .timeout(remaining)
            .timeout_connect(Duration::from_secs(30).min(remaining))
            .build();
        let response = match agent.get(url.as_str()).call() {
            Ok(response) => response,
            Err(ureq::Error::Status(status, response)) if (300..400).contains(&status) => response,
            Err(error) => return Err(format!("Updater download failed: {error}")),
        };
        if (300..400).contains(&response.status()) {
            let location = response.header("Location").ok_or("Updater redirect has no destination")?;
            url = url.join(location).map_err(|_| "Invalid updater redirect")?;
            continue;
        }
        if !(200..300).contains(&response.status()) {
            return Err(format!("Updater download returned HTTP {}", response.status()));
        }
        let expected = response.header("Content-Length")
            .map(str::parse::<usize>)
            .transpose()
            .map_err(|_| "Invalid updater content length")?;
        let bytes = read_limited(response.into_reader(), expected, deadline)?;
        let pubkey = app.config().plugins.0.get("updater")
            .and_then(|value| value.get("pubkey"))
            .and_then(|value| value.as_str())
            .ok_or("Missing updater public key")?;
        verify_signature(&bytes, &update.signature, pubkey, &update.version)?;
        return Ok(bytes);
    }
    Err("Updater redirected too many times".into())
}

/// Same verification contract as tauri-plugin-updater 2.12: global minisign signature and
/// signed `version:` trusted comment. The feed's version is not itself authenticated.
pub fn verify_signature(
    bytes: &[u8], signature_b64: &str, pubkey_b64: &str, announced_version: &str,
) -> Result<(), String> {
    let decode = |value: &str| -> Result<String, String> {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(value)
            .map_err(|_| "Invalid updater signature encoding")?;
        String::from_utf8(bytes).map_err(|_| "Invalid updater signature text".into())
    };
    let public = PublicKey::decode(&decode(pubkey_b64)?)
        .map_err(|_| "Invalid updater public key")?;
    let signature = Signature::decode(&decode(signature_b64)?)
        .map_err(|_| "Invalid updater signature")?;
    public.verify(bytes, &signature, true)
        .map_err(|_| "Updater signature verification failed")?;
    let signed_version = signature.trusted_comment()
        .split('\t')
        .find_map(|part| part.strip_prefix("version:"))
        .ok_or("Updater signature has no signed version")?;
    let signed = semver::Version::parse(signed_version.trim_start_matches('v'))
        .map_err(|_| "Invalid signed updater version")?;
    let announced = semver::Version::parse(announced_version.trim_start_matches('v'))
        .map_err(|_| "Invalid updater feed version")?;
    if signed != announced {
        return Err("Updater signature is for a different version".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE_BYTES: &[u8] = include_bytes!("../../tests/fixtures/updater/signature-fixture.bin");
    const FIXTURE_SIGNATURE: &str = include_str!("../../tests/fixtures/updater/signature-fixture.bin.sig");
    const FIXTURE_PUBLIC_KEY: &str = include_str!("../../tests/fixtures/updater/preview-public-key.txt");

    #[test]
    fn real_signed_fixture_accepts_only_original_bytes_and_signed_version() {
        assert_eq!(FIXTURE_BYTES, b"VELO signed updater integration fixture\n");
        let signature = FIXTURE_SIGNATURE.trim();
        let key = FIXTURE_PUBLIC_KEY.trim();
        verify_signature(FIXTURE_BYTES, signature, key, "0.1.1-preview.1").unwrap();
        let mut tampered = FIXTURE_BYTES.to_vec();
        tampered[0] ^= 1;
        assert!(verify_signature(&tampered, signature, key, "0.1.1-preview.1").is_err());
        assert!(verify_signature(FIXTURE_BYTES, signature, key, "0.1.1-preview.2").is_err());

        let dir = tempfile::tempdir().unwrap();
        let mut record = Stage {
            signature: signature.into(),
            ..stage(5)
        };
        write_in(dir.path(), &mut record, FIXTURE_BYTES).unwrap();
        assert_eq!(read_verified_in(dir.path(), &record, key).unwrap(), FIXTURE_BYTES);
    }

    fn stage(generation: u64) -> Stage {
        Stage {
            version: "0.1.1-preview.1".into(),
            signature: "signature".into(),
            url: "https://example.test/package".into(),
            target: "darwin-aarch64".into(),
            consent_generation: generation,
            sha256: String::new(),
            filename: String::new(),
        }
    }

    #[test]
    fn interrupted_or_tampered_stage_never_becomes_a_package() {
        let dir = tempfile::tempdir().unwrap();
        let mut record = stage(4);
        write_in(dir.path(), &mut record, b"signed package fixture").unwrap();
        assert_eq!(read_in(dir.path()).unwrap().sha256, digest(b"signed package fixture"));
        std::fs::write(dir.path().join(&record.filename), b"different package").unwrap();
        assert!(read_verified_in(dir.path(), &record, "not-a-key")
            .unwrap_err().contains("changed"));
        clear_in(dir.path());
        assert!(read_in(dir.path()).is_none());
        assert!(!dir.path().join(&record.filename).exists());
    }

    #[test]
    fn stage_metadata_never_escapes_owned_directory() {
        let dir = tempfile::tempdir().unwrap();
        let record = Stage { filename: "../../account.json".into(), ..stage(1) };
        std::fs::write(metadata_path(dir.path()), serde_json::to_vec(&record).unwrap()).unwrap();
        assert!(read_in(dir.path()).is_none());
        clear_in(dir.path());
    }

    #[test]
    fn bounded_reader_accepts_complete_bytes_and_rejects_truncation_overflow_and_timeout() {
        use std::io::Cursor;
        let future = Instant::now() + Duration::from_secs(1);
        assert_eq!(read_limited(Cursor::new(b"package"), Some(7), future).unwrap(), b"package");
        assert!(read_limited(Cursor::new(b"package"), Some(8), future)
            .unwrap_err().contains("truncated"));
        assert!(read_limited(Cursor::new(b"package"), Some(MAX_PACKAGE_BYTES + 1), future)
            .unwrap_err().contains("allowed size"));
        assert!(read_limited(Cursor::new(b"package"), None, Instant::now() - Duration::from_secs(1))
            .unwrap_err().contains("timed out"));
    }
}
