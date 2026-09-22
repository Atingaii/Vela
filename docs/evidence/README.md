# Velo preview.4 发行验证

源码提交：`c5bef3056514e221bd63f1a28e3c338a82ddfdd9`。以下为 2026-09-22 的实测记录。

- [常规 CI](https://github.com/Atingaii/Velo/actions/runs/35741468475)：macOS、Windows、浏览器均成功；详见 [机器记录](velo-ci.json)。
- [发行流水线](https://github.com/Atingaii/Velo/actions/runs/35741472156)：三个平台构建、安装启动和发布成功；详见 [机器记录](velo-release-workflow.json)。
- [公开预览版](https://github.com/Atingaii/Velo/releases/tag/v0.1.0-preview.4)：重新下载三个安装包并校验 SHA-256；见 [文件与安装报告](velo-preview-release.json)。
- [本机安装记录](velo-local-install.json)：在 macOS 27 ARM64 上挂载 DMG、复制应用、验证 ad-hoc 签名完整性、运行原生设置 WebView/IPC 检查；公开包与实测包哈希相同。
- [官网部署与浏览器记录](velo-website.json)：既有 Cloudflare Pages `velo` 生产环境，1440/390/320px 布局、图片、主题、FAQ 与下载导航通过；[公开链接检查](velo-public-http.json)、[桌面截图](velo-website-desktop.png)、[手机截图](velo-website-mobile.png)。

## 边界

安装 smoke 使用空的独立配置目录，不读取真实账户、不启动供应商采集。macOS 主程序 190 项 + helper 1 项测试通过，Windows 主程序 193 项 + helper 1 项通过；各 3 项需要已登录真实 CLI 的测试按原配置忽略。浏览器回归 17 项、Node 10 项通过。

Intel 与 Windows 安装结果来自对应 GitHub runner；本机额外复验仅覆盖 Apple Silicon。未完成真实账户、多屏、全部功能及最低系统版本验收。macOS 尚未 Apple 公证，Windows 尚未代码签名；首次安装要求见 [发行说明](../releases/preview.md)。
