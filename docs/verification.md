# 兼容性与验收

当前阶段仅推进 macOS（Apple Silicon / Intel）；Windows、Linux 暂缓，见[平台规划](platform-roadmap.md)。下方跨平台表和分批记录保留为历史实现记录，不作为当前支持清单。最新 Mac 检查点以[原生验收记录](verification/native-parity-2026-09-23/README.md)和[完整迁移清单](migration-parity.md)为准，启动 smoke 通过不等于原生 UI、真实账户或 Gatekeeper 已通过。

## 实现范围

采用 Tauri 2 / Rust 作为跨平台实现，按固定 Codenotch Swift 主线全量迁移。当前仍未通过原版 UI、效果和全部行为一致性验收；具体缺口见 [迁移清单](migration-parity.md)。首版不精简设置；迁移验收后只完成新增第 1 项插件，再暂停。

| 能力 | Windows | macOS | 本轮验证边界 |
| --- | --- | --- | --- |
| 边缘、圆环、悬浮卡片、状态机 | 复用上游实现 | 共享 UI / 坐标，原生按键适配 | Rust 状态测试；真实多屏/缩放待实机 |
| 跳回终端、完成确认 | Win32 | AppKit + 进程树 | 原生构建 CI；前台焦点待实机 |
| Claude CLI 账户、hooks、日志 | 保留 | 配置文件 + 非交互 Keychain 查询 + Terminal 登录 | 配置与 hook 测试；真实账号授权不在自动测试中 |
| Cursor、Grok、GLM | 保留 | 使用跨平台配置路径 | 解析测试；真实服务可用性不作保证 |
| Antigravity | ConPTY + Credential Manager / 本地桥 | 有界 CLI 子进程 / 本地桥 / 非交互 Keychain | 非 Windows CLI 为管道，需确认具体 agy 版本是否要求 PTY；Keychain 拒绝访问时不在后台反复弹窗 |
| Claude Desktop 网络活动推测 | Windows IO 计数 | 无对应 IO 推测 | macOS 仍可用会话日志与 hook；不能宣称推测能力等价 |
| 开机启动 | 注册表 | LaunchAgent | 文件/实现检查；登录启动待实机 |
| 通知 | 系统插件 | 系统插件 | 去重、权限失败 UI 测试；系统送达待实机 |
| 插件、中转站、剪贴板 | 历史扩展源码 | 历史扩展源码 | 首版入口关闭；阶段 1 验收后再实现/验收，不算当前交付 |
| 本地 token 用量、CLI 配置、MCP、Skill 新增工作台 | 延期 | 延期 | 既有源码保留但入口关闭，本轮不推进 |
| 原版用量节奏、Claude 每日份额 | 共享实现 | 共享实现 | 上游边界样例、设置与圆环切换浏览器回归通过；原生视觉待验收 |
| 原版 Phone Link v3 | 共享实现 + 系统凭据库 | 共享实现 + 系统凭据库 | 加密向量、配对状态、刷新完成/超时测试；真实手机与完整快照待验收 |

上游 Swift 主线还包含比 Tauri 分支更多的供应商与平台专有功能。它们未因本轮使用同一框架而自动迁移；后续逐项对齐，不能宣称所有 Swift 集成已经完整保留。现存扩展代码的测试通过不等于完成插件阶段。

## 本地自动检查

- `npm run check:ui`：4 个 WebView 页面的内联脚本语法。
- `npm test`：UI 逻辑回归（10 项）。
- `npm run test:ui`：Playwright 单 worker，17 个界面场景（含保留但不开放的扩展源码回归），使用明确的测试 IPC fixture；不把模拟桥接当真实系统集成测试。
- `cargo test --locked --workspace -- --test-threads=1`：状态、用量解析、配置变更、备份、插件和原有供应商逻辑；调用真实已安装 CLI 的测试保持 ignored。
- GitHub Actions：macOS / Windows 单任务构建与 Rust 测试，以及独立浏览器测试。最终结果以仓库当前提交的 Actions 状态为准。

## 发布前的双端手工检查

1. 单屏与双屏、不同缩放：四边移动、拖动/Alt 或 Option 拖动、热插拔、唤醒与复位；卡片不截断、不离屏。
2. Claude 会话启动、输入、等待、完成、跳回；权限拒绝与账号未登录时仍能操作设置。
3. 启动项启停后重新登录系统确认；托盘及重复启动入口可找回设置。
4. 阶段 1 验收后：拖入文件、副本打开/移除、停用再启用；剪贴板只在点击时读取，关闭窗口不留历史。
5. 手机 v3 配对、查询、等待刷新、撤销；每日份额切换时圆环、托盘与手机数据一致。
6. 安装包内 hook 的位置、签名与可执行权限；Windows WebView2、macOS Gatekeeper/公证；发布签名更新前不启用自动更新。
