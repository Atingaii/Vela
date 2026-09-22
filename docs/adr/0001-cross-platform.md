# ADR-0001 · 保留交互，迁移 Tauri 2

- 状态：Accepted
- 日期：2026-09-22

目标是让 Codenotch 的交互运行于 macOS 和 Windows，而非设计另一个产品。比较直接重写 SwiftUI、Electron 重写、复用上游 Tauri 移植：采用第三条。CC Switch 同样使用 Tauri + Rust；其 React 不是跨平台能力的必要条件。保留现有 HTML/CSS/JavaScript 可以减少重写造成的行为回归。

上游已存在 Windows Tauri 实现，复用其状态机、账户读取、边缘坐标、悬浮卡片和交互。平台相关操作放在 Rust 条件编译边界：Windows 使用 Win32；macOS 使用 AppKit、Keychain、LaunchAgent 与系统 open。UI 不直接拥有任意进程执行权限。

吸附区域统一使用系统工作区，避开 Windows 任务栏和 macOS 菜单栏 / Dock；只有系统未报告可用工作区时才退回整个屏幕。相对于 Swift 主线使用全屏边缘的行为，这是为避免系统栏遮挡所作的明确修正，拖动坐标保存与恢复采用同一区域。

删除旧仓库历史，从独立 main 初始提交开始；保留必要的上游版权与来源。旧 AGENTS 的 Antigravity 工具限制已由用户明确取消。

代价：Tauri WebView 不是 SwiftUI，系统材质、焦点和动画细节需双端实机验收。上游 Swift 主线和 Windows 分支的供应商覆盖并不完全相同，不能把“复用 Windows 移植”描述为“完整移植所有 Swift 功能”。必须用兼容性矩阵逐项标明差异。本轮核心现有适配覆盖 Claude、Codex、Cursor、Grok、Antigravity、GLM。

不引入 React、独立常驻前端进程或新远端服务。正式签名发布和自动更新要在密钥与发布流水线准备好后启用。
