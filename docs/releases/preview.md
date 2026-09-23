# Velo v0.1.1-preview.1

本轮仅交付 macOS 预览版，继续迁移固定的 Codenotch 客户端：屏幕边缘用量圆环、账户设置、会话状态与提醒。完整功能和视觉对齐仍在验收中。

## 下载与升级

- Apple Silicon（M 系列）：`Velo-macos-arm64.dmg`
- Intel Mac：`Velo-macos-x64.dmg`
- 校验文件：`SHA256SUMS.txt`；原生安装启动报告：`smoke-*.json`。

将 DMG 中的 Velo 拖入「应用程序」。Windows、Linux 暂缓，见[后续规划](https://github.com/Atingaii/Velo/blob/main/docs/platform-roadmap.md)，收到明确指示后再实施。

公开的旧 `v0.1.0-preview.4` 安装包内部版本是 `0.1.0`，没有本轮更新公钥和 feed，**不能通过应用内更新升级**。从该版本升级，请重新下载对应平台安装包。内部配置目录和系统凭据标识仍沿用 `vela`，以保留现有数据。

本版接入 Velo 自有的 HTTPS 预览更新 feed 和签名公钥。自动路径在后台检查、下载并验证更新包，等到下次启动时再交给系统安装程序；手动点「安装」会立即交接。更新包签名与操作系统的发行代码签名是两回事：它只能证明包与 Velo 的更新公钥匹配，不能代替 Apple 公证。两种 Mac 架构已通过[真实签名升级检查](https://github.com/Atingaii/Velo/actions/runs/35852348869)：使用带相同更新配置的内部 .0 验证基底，实际下载、验签、安装并重启为此版本。该结果不意味着未配置更新的旧公开 .4 可以应用内升级，也不替代完整原生界面和真实账户验收。

## 首次打开

本预览版使用 ad-hoc 签名，没有 Apple Developer ID 签名和 Apple 公证。macOS 若拦截，核对下载来源和 SHA-256 后，可在「系统设置 → 隐私与安全」选择「仍要打开」。请勿为此关闭系统保护。

## 验收边界

发布管线要求 Node、Rust、浏览器回归，并在 Apple Silicon 与 Intel Mac runner 上挂载 DMG、复制应用后启动原生应用，检查设置 WebView、Rust IPC 和包内 hook。隔离安装报告不使用真实账户，也不启动供应商采集。

完整 Swift 功能对齐、多屏和真实账户行为仍待验收。本预览版不包含文件中转或剪贴板插件。

问题反馈：https://github.com/Atingaii/Velo/issues
官网：https://velo.codes

### macOS 安装被拦截时

若提示「Apple 无法验证 Velo.app 是否包含恶意软件」，先点「完成」保留应用，再打开「系统设置 → 隐私与安全」，找到 Velo 的拦截记录，选择「仍要打开」，按系统提示确认。仅对核对过来源的 Velo 操作；如果应用已移到废纸篓，先重新从官网安装。操作路径见 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

**安装 smoke 通过不代表 Gatekeeper 通过。** `trust-macos-*.json` 分开记录签名完整性、Developer ID、Gatekeeper 和公证票据；只有 `ready_for_default_open: true` 才表示系统默认打开验收通过。签名更新的另一次隔离升级报告会检查真实包签名、版本、重启后路径、IPC 和 helper，不覆盖用户正式安装。
