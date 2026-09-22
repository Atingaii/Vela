Velo 首个跨平台预览版：屏幕边缘用量圆环、账户设置、会话状态与提醒。

## 下载

- Apple Silicon（M 系列）：`Velo-macos-arm64.dmg`
- Intel Mac：`Velo-macos-x64.dmg`
- Windows x64：`Velo-windows-x64-setup.exe`
- 校验文件：`SHA256SUMS.txt`；安装启动证据：`smoke-*.json`。

macOS 将 DMG 中的 Velo 拖入「应用程序」。Windows 运行安装程序；需要 WebView2，安装程序会按需安装。

## 首次打开

本预览版未进行商业发行签名：macOS 使用 ad-hoc 签名、没有 Apple 公证；Windows 没有代码签名证书，可能出现 SmartScreen 提示。macOS 若拦截，核对下载来源和 SHA-256 后，可在「系统设置 → 隐私与安全」选择「仍要打开」。Windows 仅在确认来源可信后通过「更多信息 → 仍要运行」继续。请勿为此关闭系统保护。

## 已验证与限制

发布管线须通过 Node / Rust / 浏览器回归；在 Apple Silicon、Intel macOS 和 Windows runner 上，从 DMG 复制 / NSIS 安装后启动原生应用，检查设置 WebView、Rust IPC 和包内 hook。报告不使用真实账户、不进行供应商采集。

完整功能对齐、多屏与真实账户行为仍在验收中。没有配置签名自动更新；升级请重新下载。内部配置目录和系统凭据标识沿用旧名称 vela，以保留已有数据。此预览版不包含可用的文件中转或剪贴板插件。

问题反馈：https://github.com/Atingaii/Velo/issues
官网：https://velo.codes
