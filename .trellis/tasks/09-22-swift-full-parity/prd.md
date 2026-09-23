# Codenotch 全量迁移

2026-09-23 最新阶段范围：先仅完成 macOS（Apple Silicon 与 Intel）的全部迁移和原生验收。Windows、Linux 只保留[后续规划](../../../docs/platform-roadmap.md)，用户明确要求后才继续；历史跨端检查不再是当前阶段的待办。技术栈与 Mac 的 1:1 标准不降低，见 [ADR 0009](../../../docs/adr/0009-macos-first-delivery.md)。

首版仅将 Swift 实现转换为 Tauri 2 / Rust / WebView 跨平台实现，保留全部逻辑、UI、视觉效果和设置。迁移核对通过后，完成新增第 1 项边缘插件机制，然后暂停。设置精简及新增第 2–4 项本轮不推进。

验收以 `docs/migration-parity.md` 为准。UI 入口、配置项或部分解析不能代替完整能力。测试低负载；真实账号、系统 UI、自动化测试分别报告。
