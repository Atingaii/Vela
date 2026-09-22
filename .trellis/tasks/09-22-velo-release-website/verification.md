# 验证进展

## 已完成
- GitHub 已更名 Atingaii/Velo，remote 同步；description、homepage=https://velo.codes 和 7 个 topics 已通过 API 回读确认。
- 旧 README 提交 0f27da2 的原始 CI 三项成功（run 35737006628）。
- 本轮 JS 页面语法 4 页通过，Node 10 项通过；品牌断言修正后本机 Chrome 单 worker 17 项通过。
- 官网资源和锚点检查通过，1440/390/320px 无溢出、图片全部加载；主题持久化、FAQ 和下载导航通过。
- Cloudflare 预览 https://10ace6ac.velo-5i0.pages.dev 已部署，使用现有 velo 项目；相同浏览器检查通过，CSP 生效、旧产品页 301、旧英文页 302、未知路径 404。
- 原站截图与样式已检查。字体与 OFL 从仓库历史恢复；Velo 头图由内置 imagegen 基于上轮图编辑，未用于伪造界面。

## 失败及修正
- preview.2 在浏览器 gate 失败：旧断言仍要求 Vela 文案。修正为 Velo，并完整重跑 17 项通过；未发布该失败版本，也没有改写标签。
- 全仓 cargo fmt --check 暴露原有 claude_auth/updater/watcher 等格式差异；本轮未批量格式化无关代码，新 smoke 模块单独 rustfmt。CI 原生构建与测试单独记录。

- 发布前代码复核发现 helper 仍唤起旧 vela 主程序；取消 preview.3，修正启动路径为 velo，并增加对 Cargo [[bin]] 声明的一致性回归测试，本机通过。

## 已完成的发行验证
- c5bef30 常规 CI：35741468475，全绿；macOS 主程序 190 + helper 1 项通过，Windows 主程序 193 + helper 1 项通过。各 3 项真实已登录 CLI 测试按原配置忽略，未声称已覆盖。
- preview.4 Apple Silicon job 成功：DMG 校验、挂载复制、codesign、原生 WebView/IPC/helper 均通过。本机 macOS 27 arm64 从同一 CI 安装包复制后再次运行成功；证据见 docs/evidence/velo-local-install.json。

## 发布与上线结果
- v0.1.0-preview.4 发布管线 35741472156 全部成功：browser、ARM64 DMG、Intel DMG、Windows NSIS、publish。三个平台均从安装产物启动原生应用并验证 WebView/IPC/helper；报告随 release 发布。
- 已从公开发布页下载三个安装包与 SHA256SUMS，三份 SHA-256 一致；ARM64 公开包与本机实际安装并启动的包逐字节一致。
- Cloudflare Pages 既有 velo 项目生产部署 4dc336e0-2cf5-4ff6-9086-d8ed36b24b65 成功，源码 c5bef30，域名 https://velo.codes。
- 正式域名 1440/390/320px 图片、布局、主题持久化、FAQ、下载导航通过，无页面异常；静态资源、三个安装包与校验文件公开 HTTP 200，未知路径 404，CSP 生效。
- 可回读的流水线、哈希、本机安装、公开 HTTP、线上布局证据保留于 docs/evidence/。

## 验证边界

没有 Developer ID/公证或 Windows 代码签名证书；预览版明确标注系统首次信任要求。原生 smoke 不读取真实账户、不启动供应商采集；不能替代真实服务、系统权限、多屏与全量功能验收。

## 清理

已停止本轮 4173/4174 预览服务并关闭专用浏览器；清理本轮下载的安装包、安装副本、临时截图/脚本、Playwright 日志、helper 测试 target 与空 Wrangler 临时目录，约 77 MB。保留 docs/evidence 中的交付证据、产品图、官网源码与可复用依赖。
