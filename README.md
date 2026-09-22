# Vela

基于 [Codenotch](https://github.com/vinzdg/codenotch) 二次开发的桌面编码伴侣。以 **Tauri 2 + Rust + HTML/CSS/JavaScript** 维护 macOS 与 Windows 的同一套代码，沿用 Codenotch 的边缘吸附、用量圆环、悬浮卡片、会话状态与跳回交互。

> 当前为 0.1.0 开发版本。已迁移 Codenotch 的 Tauri 端主流程，并补充 macOS 原生适配；不应将其视为上游 Swift 版本全部集成已经逐项完成实机验收。详见 [兼容性与验收](docs/verification.md)。

## 本轮功能

- 四边吸附、拖动定位、多屏选择、悬浮展开、会话状态与供应商额度显示。
- 设置沿用上游布局；外观只保留显示方式、尺寸、边缘、屏幕与复位，语言移至通用；通知只有等待回应、任务完成两个开关。
- **边缘扩展**：统一 Rust 插件接口、显式启停；文件中转站和点击读取的剪贴板预览。吸附栏右键 →「扩展与 CLI 工具」，或设置 → 通用 → 打开工具。
- **本地用量**：Claude Code、Codex 日志按日期、CLI、模型、项目汇总，区分输入、输出、缓存读取、缓存写入；用户自定义单价、每月账期与固定订阅金额，展示 API 等值金额与周期估计。
- **轻量供应商切换**：Claude Code / Codex / Gemini CLI 分协议保存方案；预览、备份、应用。Vela 不代理 API 请求。
- **MCP 与 Skill 复用**：一份定义生成三个 CLI 的配置。支持 stdio / HTTP MCP 与指令型 `SKILL.md`。CLI 自己处理 MCP 运行及认证。

会话观测与跨 Agent 共享记忆仅规划，见 [路线图](docs/roadmap.md)。第三方插件市场、带附件的完整技能包导入、自动计价与账单对账尚未实现。

## 开发

需要 Node.js 20+、Rust stable（当前锁定依赖需支持较新的 Rust）、macOS Xcode Command Line Tools 或 Windows MSVC Build Tools + WebView2。按 [Tauri 官方前置条件](https://v2.tauri.app/start/prerequisites/) 安装系统依赖。

```sh
npm ci
npm run dev
```

`npm run dev` 顺序构建 `vela-hook` 并启动桌面应用。Windows 用 PowerShell，macOS 用 Terminal。确保 `cargo`、`rustc` 在 PATH 中。

```sh
npm run build
```

构建当前主机的应用和安装包，输出 `target/release/bundle/`。macOS/Windows 安装包应在各自系统构建；正式分发前配置系统签名、公证与 Tauri updater 公钥。本仓库没有内置私钥，未配置签名更新源时更新按钮不可用。

## 低负载验证

```sh
npm run check:ui
npm test
npx playwright install chromium --only-shell
npm run test:ui
cargo test --locked --workspace -- --test-threads=1
```

Cargo 固定 `jobs = 1`，浏览器测试固定一个 worker。不做压力测试，不调用收费模型；测试使用临时目录和模拟 IPC，不修改本机 CLI 凭据。首次 Rust 依赖编译需要时间。Linux 用于本地静态与单元验证，不作为本轮交付目标。

`npm run preview` 只预览页面；浏览器没有桌面 IPC 时会明确报错，不伪造用量数据。

## 数据与配置

Vela 数据目录：macOS `~/Library/Application Support/vela/`；Windows `%APPDATA%/vela/`。可在通用设置中打开。新功能存放于其中 `workbench/`，与 CLI 配置分离。

- 文件中转站：复制普通文件，每件最多 50 MiB，共最多 100 件 / 500 MiB；移除只删副本。
- 剪贴板：手动读取、仅窗口内预览，不采集历史。
- 用量：只在点击刷新时读取默认 `~/.claude/projects` 与 `~/.codex/sessions`；最多 300 个日志 / 32 MiB。不会保存提示词。未识别的记录与超限会提示覆盖不完整。金额不是实际账单，预测按本机记录与用户价格计算，订阅金额单列，不重复相加。
- CLI 同步：预览后 5 分钟内应用；预览后内容改变则拒绝覆盖；原文件旁保留 `.vela-backup-*` 字节级备份。失败尝试回滚；多文件更新不是跨进程数据库事务，请关闭会同时写配置的 CLI。
- 供应商只在 Vela 资料库保存密钥环境变量名。Codex 用 `env_key`；Claude/Gemini 的适配在应用时将变量值写入对应 CLI 本地配置，预览隐藏密钥。需从继承变量的终端启动 Vela。切换后重启 CLI；项目配置、环境变量或组织策略可能覆盖用户配置。
- MCP 的命令、Skill 正文不由 Vela 执行；同步后仍需在 CLI 中确认工具信任与权限。

[配置格式与适配](docs/cli-adapters.md) · [插件开发](docs/plugins.md) · [架构决策](docs/adr/README.md)

## 来源与许可

派生自 Vinz 的 Codenotch，保留 MIT 授权、版权声明与供应商图标说明。上游参考版本与修改范围见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Vela 的 Git 历史从本次重建开始；新的 Git 历史不免除保留上游版权声明的义务。
