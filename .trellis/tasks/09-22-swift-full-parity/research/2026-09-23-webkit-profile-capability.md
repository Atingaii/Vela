# WebKit profile 能力检查前移

基线 `ca25fffff278d8cd5518338890149ecdafc47945`。固定 Swift `117a38b8edae2ebd0944bc86b8760c6381685345` 的 `Sources/Providers/WebSessionProvider.swift` 使用默认数据存储；本项目 ADR 0006 已明确每供应商独立 profile，macOS 14 以下不回退共享存储。本次不改变该兼容策略。

`window_for` 原来会检查系统能力，但 `open_web_session` 在到达它之前，可能因持久化的 signed-out 标志而先调用 `fetch_data_store_identifiers` / `remove_data_store`。当前 Wry 的枚举实现直接调用 macOS 14 才提供的 WebKit API，没有替调用方做系统版本检查。因此仅窗口创建处的门控不覆盖重开清理路径。

现在入口先验证站点和系统能力，通过后才读取待清理会话、读取退出标志或调用 profile API。无效站点仍返回 `Invalid`，不支持独立 profile 的系统返回既有 `Unavailable`。后台退出路径原有能力检查保留。

回归使用待清理会话验证不支持系统在清理前返回；受支持系统继续返回对应 cleanup epoch。另覆盖 macOS 13 / 14 / 15 与无法识别的版本。单线程全量 Rust 383 + helper 1 通过、3 ignored，日志 `/tmp/velo-websession-capability-rust.log`。这不是 macOS 12/13 实机运行证明，也不替代真实网页登录或最终界面验收。
