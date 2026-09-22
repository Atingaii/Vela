//! V1 plugins are explicitly registered Rust implementations, not arbitrary downloaded code.
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Mutex,
};
use tauri::AppHandle;
use tauri_plugin_clipboard_manager::ClipboardExt;
static LOCK: Mutex<()> = Mutex::new(());
const FILE_LIMIT: u64 = 50 * 1024 * 1024;
#[derive(Serialize)]
pub struct Manifest {
    pub id: &'static str,
    pub name: &'static str,
    pub version: u32,
    pub capabilities: &'static [&'static str],
}
pub trait EdgePlugin: Sync {
    fn manifest(&self) -> Manifest;
    fn invoke(
        &self,
        app: &AppHandle,
        root: &Path,
        action: &str,
        input: Value,
    ) -> Result<Value, String>;
}
struct Shelf;
struct Clipboard;
static PLUGINS: [&dyn EdgePlugin; 2] = [&Shelf, &Clipboard];
fn plugins_root() -> PathBuf {
    crate::workbench::root().join("plugins")
}
fn enabled(root: &Path) -> Result<Vec<String>, String> {
    match fs::read(root.join("enabled.json")) {
        Ok(b) => serde_json::from_slice(&b).map_err(|e| e.to_string()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(e.to_string()),
    }
}
#[tauri::command]
pub fn list_edge_plugins() -> Result<Value, String> {
    Ok(
        json!({"plugins": PLUGINS.iter().map(|p| p.manifest()).collect::<Vec<_>>(), "enabled": enabled(&plugins_root())?}),
    )
}
#[tauri::command]
pub fn set_edge_plugin(id: String, on: bool) -> Result<(), String> {
    let _lock = LOCK.lock().map_err(|_| "插件锁不可用")?;
    if !PLUGINS.iter().any(|p| p.manifest().id == id) {
        return Err("未知插件".into());
    }
    let root = plugins_root();
    let mut ids = enabled(&root)?;
    ids.retain(|s| s != &id);
    if on {
        ids.push(id);
    }
    crate::workbench::atomic(
        &root.join("enabled.json"),
        &serde_json::to_vec(&ids).map_err(|e| e.to_string())?,
    )
}
#[tauri::command]
pub async fn edge_plugin_action(
    app: AppHandle,
    id: String,
    action: String,
    input: Value,
) -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let _lock = LOCK.lock().map_err(|_| "插件锁不可用")?;
        let root = plugins_root();
        if !enabled(&root)?.contains(&id) {
            return Err("请先启用插件".into());
        }
        PLUGINS
            .iter()
            .find(|p| p.manifest().id == id)
            .ok_or("未知插件")?
            .invoke(&app, &root.join(&id), &action, input)
    })
    .await
    .map_err(|e| e.to_string())?
}
fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 220
        && !name.starts_with('.')
        && !name.chars().any(|c| c.is_control() || "/\\:".contains(c))
}
fn shelf_entries(root: &Path) -> Result<Vec<Value>, String> {
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for e in fs::read_dir(root).map_err(|e| e.to_string())?.take(101) {
        let e = e.map_err(|e| e.to_string())?;
        let m = e.path().symlink_metadata().map_err(|e| e.to_string())?;
        if m.is_file() && !m.file_type().is_symlink() {
            out.push(json!({"name": e.file_name().to_string_lossy(), "bytes": m.len()}));
        }
    }
    out.sort_by_key(|v| v["name"].as_str().unwrap_or("").to_owned());
    Ok(out)
}
fn add_file(root: &Path, path: &Path) -> Result<(), String> {
    let m = path.symlink_metadata().map_err(|e| e.to_string())?;
    if !m.is_file() || m.file_type().is_symlink() || m.len() > FILE_LIMIT {
        return Err("仅接收不超过 50 MiB 的普通文件".into());
    }
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| safe_name(s))
        .ok_or("文件名不受支持")?;
    let entries = shelf_entries(root)?;
    if entries.len() >= 100
        || entries
            .iter()
            .filter_map(|v| v["bytes"].as_u64())
            .sum::<u64>()
            + m.len()
            > 500 * 1024 * 1024
    {
        return Err("中转站上限为 100 个文件 / 500 MiB，请先移除部分文件".into());
    }
    fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let mut source = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut dest = tempfile::NamedTempFile::new_in(root).map_err(|e| e.to_string())?;
    use std::io::Read;
    let copied = std::io::copy(&mut (&mut source).take(FILE_LIMIT + 1), &mut dest)
        .map_err(|e| e.to_string())?;
    if copied > FILE_LIMIT {
        return Err("文件在复制期间超过大小限制".into());
    }
    dest.as_file().sync_all().map_err(|e| e.to_string())?;
    dest.persist_noclobber(root.join(name))
        .map_err(|_| "已有同名文件，请先移除中转站中的副本")?;
    Ok(())
}
impl EdgePlugin for Shelf {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "file-shelf",
            name: "文件中转站",
            version: 1,
            capabilities: &[
                "selected-files:read",
                "private-storage:write",
                "file:reveal",
            ],
        }
    }
    fn invoke(
        &self,
        _app: &AppHandle,
        root: &Path,
        action: &str,
        input: Value,
    ) -> Result<Value, String> {
        match action {
            "list" => {}
            "add" => add_file(
                root,
                Path::new(input["path"].as_str().ok_or("缺少文件路径")?),
            )?,
            "open" | "remove" => {
                let name = input["name"]
                    .as_str()
                    .filter(|s| safe_name(s))
                    .ok_or("无效文件名")?;
                let path = root.join(name);
                let m = path.symlink_metadata().map_err(|e| e.to_string())?;
                if !m.is_file() || m.file_type().is_symlink() {
                    return Err("不是中转站文件".into());
                }
                if action == "open" {
                    crate::platform::open(path.as_os_str())?;
                } else {
                    fs::remove_file(path).map_err(|e| e.to_string())?;
                }
            }
            _ => return Err("未知插件操作".into()),
        }
        Ok(json!(shelf_entries(root)?))
    }
}
impl EdgePlugin for Clipboard {
    fn manifest(&self) -> Manifest {
        Manifest {
            id: "clipboard-preview",
            name: "剪贴板预览",
            version: 1,
            capabilities: &["clipboard:read-on-click"],
        }
    }
    fn invoke(
        &self,
        app: &AppHandle,
        _root: &Path,
        action: &str,
        _input: Value,
    ) -> Result<Value, String> {
        if action != "read" {
            return Err("未知插件操作".into());
        }
        let text = app.clipboard().read_text().map_err(|e| e.to_string())?;
        if text.len() > 1024 * 1024 {
            return Err("文本超过 1 MiB，未载入预览".into());
        }
        Ok(json!({"text": text}))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shelf_copies_without_overwriting_or_touching_original() {
        let t = tempfile::tempdir().unwrap();
        let src = t.path().join("hello.txt");
        fs::write(&src, "hello").unwrap();
        let shelf = t.path().join("shelf");
        add_file(&shelf, &src).unwrap();
        assert_eq!(fs::read_to_string(&src).unwrap(), "hello");
        assert!(add_file(&shelf, &src).is_err());
        assert_eq!(shelf_entries(&shelf).unwrap().len(), 1);
    }
    #[test]
    fn traversal_and_directories_rejected() {
        for s in ["../x", "a/b", "a\\b", "C:foo", ".", ""] {
            assert!(!safe_name(s));
        }
        let t = tempfile::tempdir().unwrap();
        assert!(add_file(&t.path().join("shelf"), t.path()).is_err());
    }
}
