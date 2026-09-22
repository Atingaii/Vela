# 兼容性与验收

## 实现范围

采用 Codenotch 上游 Tauri 移植作为共享实现。源码层面保留以下路径：四边吸附与边缘位置记忆、多屏回落、大小缩放、悬浮展开、额度圆环、活动状态、会话跳转、账户与凭据读取、Claude hooks、托盘、诊断。设置中移除的控制不等于删除状态机能力。

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
| 插件、中转站、剪贴板 | 共享实现 | 共享实现 | 文件副本/路径限制单测；桌面拖入、系统剪贴板待实机 |
| 本地 token 用量 | Claude / Codex 默认目录 | 相同 | 去重、累计差分、账期、空数据测试 |
| CLI 配置、MCP、Skill | 共享适配器 | 共享适配器 | 临时目录验证备份、旧配置保留、预览冲突；CLI 真实加载待实机 |

上游 Swift 主线还包含比 Tauri 分支更多的供应商与平台专有功能。它们未因本轮使用同一框架而自动迁移；后续逐项对齐，不能宣称所有 Swift 集成已经完整保留。v1 插件是编译期机制；Skill 同步是指令型文件，不是完整带附件包管理器。

## 本地自动检查

- `npm run check:ui`：4 个 WebView 页面的内联脚本语法。
- `npm test`：继承的 UI 逻辑回归（8 项）。
- `npm run test:ui`：Playwright 单 worker，6 个端到端界面场景，使用明确的测试 IPC fixture；不把模拟桥接当真实系统集成测试。
- `cargo test --locked --workspace -- --test-threads=1`：状态、用量解析、配置变更、备份、插件和原有供应商逻辑；调用真实已安装 CLI 的测试保持 ignored。
- GitHub Actions：macOS / Windows 单任务构建与 Rust 测试，以及独立浏览器测试。最终结果以仓库当前提交的 Actions 状态为准。

## 发布前的双端手工检查

1. 单屏与双屏、不同缩放：四边移动、拖动/Alt 或 Option 拖动、热插拔、唤醒与复位；卡片不截断、不离屏。
2. Claude 会话启动、输入、等待、完成、跳回；权限拒绝与账号未登录时仍能操作设置。
3. 启动项启停后重新登录系统确认；托盘及重复启动入口可找回设置。
4. 拖入文件、副本打开/移除、停用再启用；剪贴板只在点击时读取，关闭窗口不留历史。
5. 三个 CLI 关闭后应用 MCP/Skill/供应商，重新启动确认读取目标；检查其他配置、备份与恢复。
6. 安装包内 hook 的位置、签名与可执行权限；Windows WebView2、macOS Gatekeeper/公证；发布签名更新前不启用自动更新。
