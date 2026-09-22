# Vela

基于 [Codenotch](https://github.com/vinzdg/codenotch) 的跨平台迁移，使用 **Tauri 2 + Rust + HTML/CSS/JavaScript** 支持 macOS 和 Windows。

**当前仍在全量迁移阶段，尚未达到原版 UI、效果和全部行为一致的验收标准。** 基准固定为 Codenotch Swift 主线 `117a38b8edae2ebd0944bc86b8760c6381685345`，不是其 Windows 分支的功能子集。

## 实施顺序

1. 仅转换技术实现，保留 Swift 基准的功能、设置、UI 和交互；逐项核对并验证 macOS / Windows。
2. 完成第一阶段后，实现边缘插件机制和首批文件中转、剪贴板预览插件。
3. 完成上述两项后暂停。

本轮不精简外观或通知设置，不开放新增的用量工作台、CLI 供应商切换、MCP / Skill 同步、会话观测或共享记忆。仓库中先前已有的扩展源码保留，但桌面入口暂不开放。

迁移进展与缺口以 [全量核对表](docs/migration-parity.md) 为准；决策见 [ADR 0006](docs/adr/0006-full-swift-parity-before-product-changes.md)。单元测试与浏览器模拟测试不等于原生窗口、真实账号和视觉一致性验收。

## 开发

需要 Node.js 20+、Rust stable、macOS Xcode Command Line Tools 或 Windows MSVC Build Tools + WebView2。系统依赖参见 [Tauri 官方前置条件](https://v2.tauri.app/start/prerequisites/)。

```sh
npm ci
npm run dev
```

`dev` 顺序构建 `vela-hook` 后启动桌面应用。`npm run build` 在当前主机构建；macOS / Windows 安装包分别在目标系统构建。正式分发前需要配置签名、公证及签名更新源。

## 低负载验证

以下检查依次运行，不同时启动 Cargo 构建与浏览器测试：

```sh
npm run check:ui
npm test
cargo test --locked --workspace -- --test-threads=1
npm run test:ui
```

Cargo `jobs = 1`，Playwright 一个 worker。首次运行浏览器测试前安装 `npx playwright install chromium --only-shell`。测试使用模拟 IPC 与临时数据，不调用收费模型、不修改用户 CLI 凭据、不做压力测试。Linux 用于开发检查；目标平台仍为 macOS / Windows。

`npm run preview` 仅供页面调试，不伪造账户用量。

## 数据与开发工具

配置目录为 macOS `~/Library/Application Support/vela/`、Windows `%APPDATA%/vela/`。应用保存的密钥使用 macOS Keychain / Windows Credential Manager；第三方 CLI 凭据只读。手机连接默认关闭，开启后提供局域网 v3 加密协议；配对码只在显式打开的配对窗口内有效。

仓库已初始化 Trellis，安装 mattpocock/skills 的 grill 系列技能。版本与来源见 [工具锁](docs/agents/tooling-lock.json)，工作约定见 [AGENTS.md](AGENTS.md)，开发上下文见 [CONTEXT.md](CONTEXT.md)。

## 来源与许可

派生自 Vinz 的 Codenotch，保留 MIT 授权、版权及图标来源。见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Swift 图标通过可复现脚本直接复制资源或转换原始坐标，未重新绘制供应商品牌。
