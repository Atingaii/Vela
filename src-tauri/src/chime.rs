//! SessionChime.swift: deterministic sound discovery and a retained native player.
use std::path::{Path, PathBuf};

const EXTENSIONS: [&str; 5] = ["aiff", "aif", "m4a", "wav", "caf"];

fn directories() -> Vec<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let mut dirs = Vec::new();
        if let Some(home) = dirs::home_dir() {
            dirs.push(home.join("Library/Sounds"));
        }
        dirs.extend([
            PathBuf::from("/Library/Sounds"),
            PathBuf::from("/System/Library/Sounds"),
        ]);
        dirs
    }
    #[cfg(windows)]
    {
        std::env::var_os("SystemRoot")
            .map(|root| vec![PathBuf::from(root).join("Media")])
            .unwrap_or_default()
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        Vec::new()
    }
}

fn available_in(directories: &[PathBuf]) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    let mut names = Vec::new();
    for directory in directories {
        let Ok(files) = std::fs::read_dir(directory) else {
            continue;
        };
        let mut files = files
            .flatten()
            .map(|entry| entry.file_name())
            .collect::<Vec<_>>();
        files.sort();
        for file in files {
            let path = Path::new(&file);
            let Some(ext) = path.extension().and_then(|ext| ext.to_str()) else {
                continue;
            };
            if !EXTENSIONS.contains(&ext.to_ascii_lowercase().as_str()) {
                continue;
            }
            #[cfg(windows)]
            if !ext.eq_ignore_ascii_case("wav") {
                continue;
            }
            let Some(name) = path.file_stem().and_then(|stem| stem.to_str()) else {
                continue;
            };
            if seen.insert(name.to_owned()) {
                names.push(name.to_owned());
            }
        }
    }
    #[cfg(target_os = "macos")]
    names.sort_by(|a, b| {
        use objc2_foundation::{NSComparisonResult, NSString};
        let a = NSString::from_str(a);
        let b = NSString::from_str(b);
        match a.localizedCaseInsensitiveCompare(&b) {
            NSComparisonResult::Ascending => std::cmp::Ordering::Less,
            NSComparisonResult::Descending => std::cmp::Ordering::Greater,
            NSComparisonResult::Same => std::cmp::Ordering::Equal,
        }
    });
    #[cfg(not(target_os = "macos"))]
    names.sort_by_key(|name| name.to_lowercase());
    names
}

fn url_for_in(name: &str, directories: &[PathBuf]) -> Option<PathBuf> {
    if !available_in(directories)
        .iter()
        .any(|candidate| candidate == name)
    {
        return None;
    }
    for directory in directories {
        for ext in EXTENSIONS {
            #[cfg(windows)]
            if ext != "wav" {
                continue;
            }
            let path = directory.join(format!("{name}.{ext}"));
            if path.exists() {
                return Some(path);
            }
        }
    }
    None
}

#[tauri::command]
pub fn get_alert_sounds() -> Vec<String> {
    available_in(&directories())
}

#[tauri::command]
pub fn preview_alert_sound(name: String) -> Result<(), String> {
    play(&name)
}

pub fn play(name: &str) -> Result<(), String> {
    let path = url_for_in(name, &directories()).ok_or("找不到所选提示音，请重新选择")?;
    #[cfg(target_os = "macos")]
    {
        return macos::play(path, name);
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "winmm")]
        extern "system" {
            fn PlaySoundW(sound: *const u16, module: *mut std::ffi::c_void, flags: u32) -> i32;
        }
        let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        // SND_FILENAME | SND_ASYNC | SND_NODEFAULT; owned file path, never a command.
        if unsafe { PlaySoundW(wide.as_ptr(), std::ptr::null_mut(), 0x20000 | 1 | 2) } == 0 {
            Err("无法播放提示音".into())
        } else {
            Ok(())
        }
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        let _ = path;
        Err("此平台没有桌面提示音适配".into())
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use objc2::{
        msg_send,
        rc::Retained,
        runtime::{AnyClass, AnyObject},
    };
    use objc2_foundation::{NSError, NSString, NSURL};
    use std::sync::{mpsc, OnceLock};
    use std::time::Duration;

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {}

    struct Request {
        path: PathBuf,
        name: String,
        answer: mpsc::Sender<bool>,
    }
    static PLAYER: OnceLock<Option<mpsc::Sender<Request>>> = OnceLock::new();

    pub(super) fn play(path: PathBuf, name: &str) -> Result<(), String> {
        let sender = PLAYER.get_or_init(|| {
            let (sender, receiver) = mpsc::channel::<Request>();
            std::thread::Builder::new()
                .name("vela-session-chime".into())
                .spawn(move || player_loop(receiver))
                .ok()
                .map(|_| sender)
        });
        let sender = sender.as_ref().ok_or("无法播放提示音")?;
        let (answer, result) = mpsc::channel();
        sender
            .send(Request {
                path,
                name: name.into(),
                answer,
            })
            .map_err(|_| "无法播放提示音")?;
        if result.recv_timeout(Duration::from_secs(5)).unwrap_or(false) {
            Ok(())
        } else {
            Err("无法播放提示音".into())
        }
    }

    fn player_loop(receiver: mpsc::Receiver<Request>) {
        let mut playing: Option<Retained<AnyObject>> = None;
        for request in receiver {
            let started = objc2::rc::autoreleasepool(|_| {
                let Some(player) = new_player(&request.path) else {
                    return fallback(&request.name);
                };
                let _: bool = unsafe { msg_send![&*player, prepareToPlay] };
                playing = Some(player);
                // Swift retains the new player before calling play(), even when play says no.
                unsafe { msg_send![&**playing.as_ref().unwrap(), play] }
            });
            let _ = request.answer.send(started);
            let _ = playing.as_ref(); // Retain the last player until it is replaced or the app exits.
        }
    }

    fn new_player(path: &Path) -> Option<Retained<AnyObject>> {
        let class = AnyClass::get(c"AVAudioPlayer")?;
        let url = NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()));
        let mut error: *mut NSError = std::ptr::null_mut();
        let allocated: *mut AnyObject = unsafe { msg_send![class, alloc] };
        let raw: *mut AnyObject =
            unsafe { msg_send![allocated, initWithContentsOfURL: &*url, error: &mut error] };
        unsafe { Retained::from_raw(raw) }
    }

    #[cfg(test)]
    pub(super) fn prepare_without_play(path: &Path) -> bool {
        objc2::rc::autoreleasepool(|_| {
            let Some(player) = new_player(path) else {
                return false;
            };
            let _: bool = unsafe { msg_send![&*player, prepareToPlay] };
            true
        })
    }

    fn fallback(name: &str) -> bool {
        let Some(class) = AnyClass::get(c"NSSound") else {
            return false;
        };
        let sound: *mut AnyObject =
            unsafe { msg_send![class, soundNamed: &*NSString::from_str(name)] };
        !sound.is_null() && unsafe { msg_send![sound, play] }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(target_os = "macos")]
    #[test]
    fn user_directory_and_extension_order_override_system_without_audio() {
        let temp = tempfile::tempdir().unwrap();
        let user = temp.path().join("user");
        let system = temp.path().join("system");
        std::fs::create_dir_all(&user).unwrap();
        std::fs::create_dir_all(&system).unwrap();
        std::fs::write(user.join("Glass.wav"), b"invalid audio").unwrap();
        std::fs::write(user.join("Glass.aiff"), b"invalid audio").unwrap();
        std::fs::write(system.join("Glass.aiff"), b"invalid audio").unwrap();
        std::fs::write(system.join("Funk.aiff"), b"invalid audio").unwrap();
        let dirs = [user.clone(), system.clone()];
        assert_eq!(url_for_in("Glass", &dirs), Some(user.join("Glass.aiff")));
        assert_eq!(
            available_in(&dirs)
                .iter()
                .filter(|name| *name == "Glass")
                .count(),
            1
        );
        assert!(url_for_in("../Glass", &dirs).is_none());
    }

    #[test]
    fn invalid_name_never_starts_audio() {
        assert!(url_for_in("missing", &[]).is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn av_audio_player_prepares_valid_silence_without_playing() {
        assert!(objc2::runtime::AnyClass::get(c"AVAudioPlayer").is_some());
        let temp = tempfile::tempdir().unwrap();
        let file = temp.path().join("silent.wav");
        // PCM, mono, 8 kHz, 16 bits, 16 zero samples. No playback call is made.
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&68_u32.to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&8_000_u32.to_le_bytes());
        wav.extend_from_slice(&16_000_u32.to_le_bytes());
        wav.extend_from_slice(&2_u16.to_le_bytes());
        wav.extend_from_slice(&16_u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&32_u32.to_le_bytes());
        wav.extend_from_slice(&[0_u8; 32]);
        std::fs::write(&file, wav).unwrap();
        assert!(macos::prepare_without_play(&file));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn malformed_audio_fails_after_native_initialization_without_audible_fallback() {
        assert!(objc2::runtime::AnyClass::get(c"AVAudioPlayer").is_some());
        let temp = tempfile::tempdir().unwrap();
        let name = format!(
            "VeloInvalidSound-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let file = temp.path().join(format!("{name}.aiff"));
        std::fs::write(&file, b"not an audio container").unwrap();
        assert!(macos::play(file, &name).is_err());
    }
}
