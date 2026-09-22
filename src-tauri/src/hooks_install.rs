//! Merges vela-hook.exe into ~/.claude/settings.json without overwriting the user's own hooks.
//! Identification: the command contains "vela-hook". A backup is written first.

use serde_json::{json, Value};
use std::path::PathBuf;

/// (Claude Code event name, whether it needs a matcher, the internal event reported to Vela)
const WIRING: &[(&str, bool, &str)] = &[
    ("SessionStart", false, "session_start"),
    ("UserPromptSubmit", false, "running"),
    ("PreToolUse", true, "running"),
    ("PostToolUse", true, "running"),
    ("Notification", false, "attention"),
    ("Stop", false, "done"),
    ("SessionEnd", false, "session_end"),
];

fn settings_path() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".claude").join("settings.json"))
}

fn is_ours(entry: &Value) -> bool {
    entry["hooks"]
        .as_array()
        .map(|hs| {
            hs.iter().any(|h| {
                h["command"]
                    .as_str()
                    .map(|c| {
                        c.starts_with("\"")
                            && (c.contains("\\vela-hook.exe\" ") || c.contains("/vela-hook.exe\" "))
                            || c.starts_with("'") && c.contains("/vela-hook' ")
                    })
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn load(path: &PathBuf) -> Result<Value, String> {
    match std::fs::read(path) {
        Ok(data) => {
            let root: Value = serde_json::from_slice(&data)
                .map_err(|e| format!("Invalid Claude settings, left unchanged: {e}"))?;
            if !root.is_object() {
                return Err("Claude settings must be an object; left unchanged".into());
            }
            if !root["hooks"].is_null() && !root["hooks"].is_object() {
                return Err("Invalid hooks configuration; left unchanged".into());
            }
            Ok(root)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(e) => Err(e.to_string()),
    }
}

fn backup_and_write(path: &PathBuf, root: &Value) -> Result<(), String> {
    use std::io::Write;
    let dir = path.parent().ok_or("Missing settings directory")?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    if path.exists() {
        let mut backup = tempfile::Builder::new()
            .prefix("settings.json.vela-backup-")
            .tempfile_in(dir)
            .map_err(|e| e.to_string())?;
        let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
        backup
            .write_all(&bytes)
            .and_then(|_| backup.as_file().sync_all())
            .map_err(|e| e.to_string())?;
        backup.keep().map_err(|e| e.error.to_string())?;
    }
    let mut tmp = tempfile::NamedTempFile::new_in(dir).map_err(|e| e.to_string())?;
    if let Ok(meta) = std::fs::metadata(path) {
        tmp.as_file()
            .set_permissions(meta.permissions())
            .map_err(|e| e.to_string())?;
    }
    tmp.write_all(&serde_json::to_vec_pretty(root).map_err(|e| e.to_string())?)
        .and_then(|_| tmp.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    tmp.persist(path).map_err(|e| e.error.to_string())?;
    Ok(())
}

pub fn is_installed() -> bool {
    settings_path()
        .and_then(|p| load(&p).ok())
        .and_then(|v| v["hooks"].as_object().cloned())
        .is_some_and(|events| {
            events
                .values()
                .filter_map(Value::as_array)
                .flatten()
                .any(is_ours)
        })
}

pub fn install() -> Result<String, String> {
    let path = settings_path().ok_or("cannot find the user directory")?;
    let hook_exe = std::env::current_exe()
        .map_err(|e| e.to_string())?
        .parent()
        .ok_or("cannot locate the program directory")?
        .join(if cfg!(windows) {
            "vela-hook.exe"
        } else {
            "vela-hook"
        });
    if !hook_exe.exists() {
        return Err(format!("missing {}", hook_exe.display()));
    }

    let mut root = load(&path)?;
    if !root.is_object() {
        root = json!({});
    }
    if !root["hooks"].is_object() {
        root["hooks"] = json!({});
    }

    for (event, need_matcher, internal) in WIRING {
        if !root["hooks"][*event].is_null() && !root["hooks"][*event].is_array() {
            return Err(format!("Invalid {event} hooks; left unchanged"));
        }
        let arr = root["hooks"][*event]
            .as_array()
            .cloned()
            .unwrap_or_default();
        // Remove our own older entries first
        let mut arr: Vec<Value> = arr.into_iter().filter_map(without_ours).collect();
        let executable = if cfg!(windows) {
            format!("\"{}\"", hook_exe.display())
        } else {
            crate::platform::shell_quote(&hook_exe.to_string_lossy())
        };
        let cmd = format!("{executable} {internal}");
        let mut entry = json!({
            "hooks": [{ "type": "command", "command": cmd, "timeout": 5 }]
        });
        if *need_matcher {
            entry["matcher"] = json!("*");
        }
        arr.push(entry);
        root["hooks"][*event] = json!(arr);
    }

    backup_and_write(&path, &root)?;
    Ok(format!(
        "wrote {} ({} events)",
        path.display(),
        WIRING.len()
    ))
}

pub fn uninstall() -> Result<String, String> {
    let path = settings_path().ok_or("cannot find the user directory")?;
    if !path.exists() {
        return Ok("settings.json does not exist, nothing to uninstall".into());
    }
    let mut root = load(&path)?;
    let Some(hooks) = root["hooks"].as_object_mut() else {
        return Ok("no hooks configuration found".into());
    };
    let mut removed = 0;
    for (_, v) in hooks.iter_mut() {
        if let Some(arr) = v.as_array() {
            let filtered: Vec<Value> = arr.iter().cloned().filter_map(without_ours).collect();
            removed += arr.len() - filtered.len();
            *v = json!(filtered);
        }
    }
    backup_and_write(&path, &root)?;
    Ok(format!("removed {removed} Vela hook(s)"))
}

fn without_ours(mut entry: Value) -> Option<Value> {
    if !is_ours(&entry) {
        return Some(entry);
    }
    if let Some(hooks) = entry["hooks"].as_array_mut() {
        hooks.retain(|h| !is_ours(&json!({ "hooks": [h] })));
        if hooks.is_empty() {
            return None;
        }
    }
    Some(entry)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_settings_remain_untouched() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("settings.json");
        std::fs::write(&p, b"{broken").unwrap();
        assert!(load(&p).is_err());
        assert_eq!(std::fs::read(&p).unwrap(), b"{broken");
    }
    #[test]
    fn uninstall_preserves_other_commands_in_the_same_group() {
        let entry = json!({"matcher":"*","hooks":[{"command":"'/Applications/Vela.app/Contents/MacOS/vela-hook' done"},{"command":"codenotch-hook done"},{"command":"echo mine"}]});
        let kept = without_ours(entry).unwrap();
        assert_eq!(kept["hooks"].as_array().unwrap().len(), 2);
        assert_eq!(kept["matcher"], "*");
    }
    #[test]
    fn unrelated_similar_binary_is_not_a_vela_hook() {
        assert!(!is_ours(
            &json!({"hooks":[{"command": "\"C:\\tools\\my-vela-hook.exe\" done"}]})
        ));
        assert!(is_ours(
            &json!({"hooks":[{"command": "\"C:\\tools\\vela-hook.exe\" done"}]})
        ));
    }
    #[test]
    fn write_keeps_a_byte_exact_backup() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("settings.json");
        std::fs::write(&p, b"{ \"custom\": true }").unwrap();
        backup_and_write(&p, &json!({"custom":true,"hooks":{}})).unwrap();
        let backups: Vec<_> = std::fs::read_dir(d.path())
            .unwrap()
            .flatten()
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("settings.json.vela-backup-")
            })
            .collect();
        assert_eq!(backups.len(), 1);
        assert_eq!(
            std::fs::read(backups[0].path()).unwrap(),
            b"{ \"custom\": true }"
        );
    }
}
