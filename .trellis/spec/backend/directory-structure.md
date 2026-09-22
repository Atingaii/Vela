# 后端目录

`src-tauri/src/main.rs` 注册 IPC、窗口和后台线程；`config.rs` 管理配置。原有供应商在 `usage.rs`、`codex.rs` 等模块；新增适配器在 `providers/`，纯解析在 `providers/parse.rs`，传输在 `providers/transport.rs`。`platform.rs` 封装原生差异。`ledger.rs`、`cli_sync.rs`、`edge_plugins.rs` 分别承载账本、CLI 同步、边缘插件。

添加命令时同时核对 main.rs 注册、Tauri capability 和 HTML 调用者，不只添加 Rust 函数。平台代码用 cfg 条件编译，公共协议保持一致。
