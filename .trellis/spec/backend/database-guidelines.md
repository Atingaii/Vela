# 存储

配置来自 `config.rs` 的 serde 结构体，新增字段必须有兼容默认值；保存使用 `save_checked`，成功落盘后才替换内存。供应商缓存使用 `providers.rs::persist` 原子替换。

读取第三方 SQLite（例如 `providers/gemini_logs.rs`）使用只读连接、限定查询范围和返回行数；不要改写 CLI 数据库。账本的写入规则见 `ledger.rs`。密钥不能写到 Config、账本、Trellis 文件或测试快照；`secrets.rs` 使用 macOS Keychain / Windows Credential Manager。
