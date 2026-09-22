//! Enumerate and play local system sound files through the ordinary audio output.
use std::{collections::BTreeMap, path::PathBuf};

fn sounds() -> BTreeMap<String, PathBuf> {
    #[allow(unused_mut)]
    let mut directories: Vec<PathBuf> = Vec::new();
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = dirs::home_dir() {
            directories.push(home.join("Library/Sounds"));
        }
        directories.extend([
            PathBuf::from("/Library/Sounds"),
            PathBuf::from("/System/Library/Sounds"),
        ]);
    }
    #[cfg(windows)]
    if let Some(root) = std::env::var_os("SystemRoot") {
        directories.push(PathBuf::from(root).join("Media"));
    }
    let mut result = BTreeMap::new();
    for directory in directories {
        for entry in std::fs::read_dir(directory)
            .into_iter()
            .flatten()
            .flatten()
            .take(512)
        {
            let path = entry.path();
            let ext = path
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if !matches!(ext.as_str(), "aiff" | "aif" | "m4a" | "wav" | "caf") || !path.is_file() {
                continue;
            }
            #[cfg(windows)]
            if ext != "wav" {
                continue;
            }
            if let Some(name) = path.file_stem().and_then(|s| s.to_str()) {
                result.entry(name.to_owned()).or_insert(path);
            }
        }
    }
    result
}
#[tauri::command]
pub fn get_alert_sounds() -> Vec<String> {
    sounds().into_keys().collect()
}

#[tauri::command]
pub fn preview_alert_sound(name: String) -> Result<(), String> {
    play(&name)
}

pub fn play(name: &str) -> Result<(), String> {
    let available = sounds();
    let path = available.get(name).ok_or("找不到所选提示音，请重新选择")?;
    #[cfg(target_os = "macos")]
    {
        // Keep a single player. Changing the selection never leaves a chorus of processes.
        static PLAYER: std::sync::Mutex<Option<std::process::Child>> = std::sync::Mutex::new(None);
        let mut player = PLAYER.lock().unwrap();
        if let Some(mut previous) = player.take() {
            let _ = previous.kill();
            let _ = previous.wait();
        }
        *player = Some(
            std::process::Command::new("/usr/bin/afplay")
                .arg(path)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .map_err(|_| "无法播放提示音")?,
        );
        Ok(())
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
