# 边缘插件开发

入口：`src-tauri/src/edge_plugins.rs`。

```rust
pub trait EdgePlugin: Sync {
    fn manifest(&self) -> Manifest;
    fn invoke(&self, app: &AppHandle, root: &Path,
              action: &str, input: Value) -> Result<Value, String>;
}
```

新增实现后注册到 `PLUGINS`，工具页调用 `list_edge_plugins`、`set_edge_plugin`、`edge_plugin_action`。统一入口拒绝未启用插件；`root` 是插件独立存储目录。扩展应明确能力、大小限制和错误状态，耗时工作运行于 blocking 工作线程。

v1 的清单用于说明能力，插件代码与主程序同等信任，不是面向恶意插件的沙箱。不要把外部路径或命令直接交给动态插件。插件测试使用临时目录，不访问用户真实剪贴板或文件。

- `file-shelf`：`list` / `add {path}` / `open {name}` / `remove {name}`。
- `clipboard-preview`：`read`；仅按用户点击调用。

每次新增插件需补充操作、权限、失败与停用行为；将来“吸附到边缘”更多面板复用这个入口。
