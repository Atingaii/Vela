# Vela

**The engineering layer for coding agents.**

[English](README.md) · [官方网站](https://vela-engineering.zzzsssaa.chatgpt.site) · [下载预览版](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.1) · [贡献指南](CONTRIBUTING.md)

[![CI](https://github.com/Atingaii/Vela/actions/workflows/ci.yml/badge.svg)](https://github.com/Atingaii/Vela/actions/workflows/ci.yml)
[![MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**让一次 Agent Session 结束，但工程经验不结束。**

Vela 是 macOS 上的本地工程工作台，整理受支持的 Claude Code、Codex 和 Cursor 会话数据，将对话证据、项目 Memory、可审批的 Workflow 和命令对照记录放在一起，配合已有 Coding Agent 使用。

> **0.1.0-preview.1 · 开发者预览版。** 核心路径已经实现，但适配、自动化和评测仍有明确限制；当前版本不代表完整产品路线图已经交付，也不是稳定版本。开发包使用 ad-hoc 签名，没有 Developer ID 签名，尚未通过 Apple 公证。使用前请阅读[功能状态与限制](docs/status.md)。

## 当前可用能力

- **观察会话**：查看统一的消息和受支持工具事件、扫描项目 Setup、汇总本地日志报告的 token。状态推断与不完整历史明确标记。
- **保留上下文**：保存带来源和作用域的 Memory，以保守预算召回 Active 内容，导出包含用户记录和真实 Git 快照的 Checkpoint。
- **审阅后执行**：编辑 Markdown Workflow，Dry Run 支持的只读工具，审批冻结的动作快照，查看持久化运行记录。项目测试和 Agent 命令需要审批。
- **比较实际结果**：检查确定性规则提取的纠错建议，预览并安全应用/撤销受支持的文件变更，在同一 Git 提交的独立 worktree 中运行 baseline/candidate 命令。
- **管理资料**：导入文本、HTML、可提取文字的 PDF、DOCX 或明确指定的文档 URL。Library 默认私有；私有资料不进入 Agent Search 或 Recall。

客户端包含 **Agents、Workflows、Setup、Usage、Improve、Lab** 六个一级页面。Memory、Guidelines、Library 位于 Setup；Search、Inbox 和 Settings 是全局入口。

## 安装

在 [0.1.0-preview.1 发布页](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.1)下载 Apple Silicon 压缩包和 `SHA256SUMS`，核对校验值后，将 `Vela.app` 移入 Applications。最低系统要求为 **macOS 13**；本预览版不提供 Intel 构建。

开发包为 **ad-hoc 签名、未公证**应用。审阅源码与发布说明后，macOS 可能要求通过针对单个应用的“仍要打开”流程放行；不要关闭全局 Gatekeeper。预览期间存储格式可能调整，请自行备份重要的 Vela 数据。

## 从源码构建

需要 Apple Silicon Mac、Git，以及提供 **Swift 5.9+** 的 Xcode Command Line Tools。GUI 的 SwiftPM 产品名是 `VelaDesktop`，CLI 是 `vela`，打包后的应用名是 `Vela.app`。

```sh
git clone https://github.com/Atingaii/Vela.git
cd Vela
swift build
swift run VelaDesktop
```

打包本地应用还需要 Python 3：

```sh
bash scripts/package-macos.sh
open releases/Vela.app
```

打包脚本默认使用 `dev` 通道，输出 `releases/Vela-macOS-arm64.zip` 和 `releases/SHA256SUMS`。设置通道本身不会完成 Developer ID 签名、公证或公开发布。安装后的应用使用 Swift、AppKit、系统 WKWebView、SQLite 等 macOS 框架，不依赖 Electron、Node.js 或 Python 运行时。

## 添加项目与使用 CLI

在客户端添加项目目录后，查看 Sessions 和 Setup。登记项目不等于批准运行项目脚本。首次发现只读取有数量与窗口限制的近期日志，不会导入全部历史。

```sh
swift run vela doctor
swift run vela call projects.add '{"path":"/absolute/path/to/project"}'
swift run vela refresh
swift run vela search 'verification'
swift run vela recall '项目约束' --project /absolute/path/to/project
```

通过 `VELA_HOME` 或 `--home /absolute/path/to/store` 选择数据目录。独立 CLI 默认使用 `~/.vela`；打包桌面应用的不同通道使用独立目录。让 CLI 和 MCP 指向你实际使用的桌面数据目录。

## MCP 接入

在 Agent 配置中添加 stdio MCP 服务，指定安装后的 helper 和桌面数据目录：

```json
{
  "mcpServers": {
    "vela": {
      "command": "/Applications/Vela.app/Contents/MacOS/vela",
      "args": ["mcp", "--home", "/absolute/path/to/.vela-dev"]
    }
  }
}
```

只读工具提供受支持的 Search、Recall 和上下文记录，请求必须显式指定已登记的目标项目。增加 `--contribute` 后，可创建候选 Memory、Checkpoint、绑定真实会话的 Signal 及 Suggestion Draft；不能激活已有 Memory、应用建议或执行 Workflow。私有 Library 不会通过 Agent 检索返回。

## 预览版的重要边界

- 初始摄取最多选择**每个 provider 60 个近期来源文件**，按需读取 **256 KB 尾窗和 32 KB 文件头**。保留的消息也有上限；尚未实现完整历史回填与原生 Session 迁移。Cursor 仅适配导出格式和部分已知 SQLite 记录。
- **Usage 是已观察到的日志用量**。订阅额度、重置检测、定价和 `usage_reset` 触发器不可用。
- Workflow Draft 与 Improve 使用**确定性的本地规则**，不具备通用自然语言规划或模型驱动的完整改进管线。
- Guidelines 支持保存与运行快照，**尚未注入 Agent 提示词**。
- Lab 提供**配对命令对照**，不是完整 Agent Benchmark。退出码与耗时不能单独证明任务成功、规则遵循或 token 节省。
- 定时触发只在应用/helper 运行期间工作，没有独立系统守护进程，也不会在休眠或关机后补跑错过的任务。

完整边界见[功能状态](docs/status.md)，后续目标见[需求与路线图](docs/requirements.md)。

## 验证源码

完整 Xcode 安装提供 XCTest：

```sh
swift test
```

仅安装 Command Line Tools 时，先构建，再使用 portable runner：

```sh
swift build
python3 scripts/test-portable.py
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

Portable runner 将真实核心与原有同步测试方法一起编译，仅提供小型断言兼容层，**不等同于 XCTest**。RPC/MCP 黑盒测试会调用已编译的 CLI，并使用一次性数据目录。仓库检查需要 Node.js 校验 JavaScript；这些开发工具不进入安装包。

## 数据与架构

会话索引和运行记录保存在本地 SQLite WAL。Memory、Workflow、Guideline、Library 和 Checkpoint 同时保存为数据目录 `assets/` 下的可读 Markdown。Vela 无需账户，没有托管 Memory 服务，也不启用遥测。

明确导入 URL 会发起网络请求；获批的 Agent 命令可能向对应 provider 发送指定上下文。Vela 不会自动把会话历史提交给外部模型。

AppKit/WKWebView 界面通过受限 JSONL RPC 与独立 `vela` helper 通信，使用 FSEvents 驱动增量摄取。官网采用静态 HTML、CSS 和 JavaScript。技术说明见[架构文档](docs/architecture.md)与 [ADR 0001](docs/adr/0001-native-macos-core.md)；性能目标不会作为已测量的保证。

已执行的验证和初步内存、搜索延迟测量见[验收记录](docs/verification.md)。

## 贡献与许可证

欢迎提交可复现的问题和范围明确的改进。请阅读[贡献指南](CONTRIBUTING.md)、[安全报告流程](SECURITY.md)与[行为准则](CODE_OF_CONDUCT.md)。

产品方向参考了用户提供的 Blume 分析、Walrus Memory/MemWal 的上下文所有权思想和 [px0](https://px0.ai/) 工作流设计。Vela 是独立实现，与参考项目及 Agent 厂商无隶属关系；不包含它们的私有源码、提示词或品牌素材。初始桌面与官网界面通过指定的 Antigravity CLI Gemini 3.8 Flash（High）工作流实现。

[MIT License](LICENSE) © Vela contributors。
