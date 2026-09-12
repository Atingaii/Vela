# ADR 0001：原生 macOS 核心与系统 WebKit 界面

- 状态：Accepted
- 日期：2026-09-12

## 背景

Vela 首发仅面向 macOS，用户要求低占用、良好性能、可安装客户端及官网。产品草案提出 Electron + Rust parser，但同一草案把低常驻开销作为验收目标，并明确近期不做跨平台。当前开发机具备 Swift 6.3.3 和 macOS SDK，仓库为空。

## 决策

采用 Swift Package Manager 管理无第三方运行时依赖的 Swift 核心、独立 `vela` CLI/JSONL RPC helper，以及 AppKit 外壳。系统 WKWebView 加载随包分发的 HTML/CSS/JavaScript。全部 UI 由用户指定的 Antigravity CLI `gemini-3.8-flash-high` 创建。官网使用独立静态资源目录并由 Sites 托管。

SQLite 使用系统 sqlite3，开启 WAL。系统 FSEvents 触发增量日志摄取。窗口进程不承担解析、数据库查询或工作流执行；关闭窗口保留菜单栏，退出应用停止 helper。没有额外常驻服务、Node 或 Chromium 分发。

## 比较与取舍

| 路线 | 收益 | 成本和约束 |
|---|---|---|
| Electron + Node + Rust | Web 生态及 CLI 进程支持成熟，跨平台方便 | 打包 Chromium/Node；ABI、原生依赖和多个运行时维护成本；性能需额外约束 |
| Tauri + Rust | 系统 WebView、可跨平台 | 当前需新增 Rust 工具链；Mac 平台集成与跨语言桥接成本 |
| Swift + AppKit + WebKit（采用） | 系统框架、少运行时依赖、菜单栏和文件事件直接可用 | 近期绑定 macOS；前后端桥接自维护；WebKit 窗口仍有独立进程开销 |

这是按当前约束作出的工程选择，未声称已完成三种实现的性能对比。验收报告必须给出实测条件与结果；目标不等于已达标。

## 安全边界

Renderer 无通用 shell 或文件 API，无业务外网访问。枚举 RPC 方法，核心验证输入。项目扫描只读；修改受显式路径边界、内容 hash、冻结审批和原子写保护。会话与长期资产保留本地，任何调用已登录 Agent CLI 的操作必须明确会将上下文提交给相应模型服务。私有 Library 在 agent 检索层禁止返回。

## 重新评估条件

用户明确需要跨平台，或实际证明 WebKit 兼容性/Swift 生态阻止关键端到端路径时再评估；不会因发现新框架改栈。

## 依据

- 用户 Vela 产品草案 §§49–64（技术建议与性能/发布目标）。
- 用户 Blume 架构报告（独立 worker、有限写入、增量摄取设计）；只作为用户提供的分析材料，未独立验证其私有实现。
- [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview/)
- [Apple File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Swift PackageDescription](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html)
