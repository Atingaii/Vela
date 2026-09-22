//! The extension window is created on demand; no hidden WebView or background polling.
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};
#[tauri::command]
pub fn open_workbench(app: AppHandle) {
    let handle = app.clone();
    std::thread::spawn(move || {
        let _ = handle.run_on_main_thread(move || {
            if let Some(w) = app.get_webview_window("workbench") {
                let _ = w.show();
                let _ = w.set_focus();
                return;
            }
            if let Err(e) = WebviewWindowBuilder::new(
                &app,
                "workbench",
                WebviewUrl::App("workbench.html".into()),
            )
            .title("Vela · 工具")
            .inner_size(980.0, 720.0)
            .min_inner_size(760.0, 560.0)
            .center()
            .build()
            {
                crate::applog(&format!("workbench: {e}"));
            }
        });
    });
}
pub fn root() -> std::path::PathBuf {
    crate::config::config_path().with_file_name("workbench")
}
pub fn atomic(path: &std::path::Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let parent = path.parent().ok_or("无父目录")?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    let mut f = tempfile::NamedTempFile::new_in(parent).map_err(|e| e.to_string())?;
    if let Ok(m) = std::fs::metadata(path) {
        f.as_file()
            .set_permissions(m.permissions())
            .map_err(|e| e.to_string())?;
    }
    f.write_all(bytes)
        .and_then(|_| f.as_file().sync_all())
        .map_err(|e| e.to_string())?;
    f.persist(path).map_err(|e| e.to_string())?;
    Ok(())
}
