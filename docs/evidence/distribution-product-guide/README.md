# 安装信任与产品说明验收

日期：2026-09-23（Asia/Shanghai）。发布验证代码 `656adab`；官网代码 `e9119b2`。

## 安装结论

用户确认没有 Apple Developer 账号。本机有效签名身份为 0，仓库未配置签名凭据。preview.4 公共 ARM DMG SHA-256 一致、磁盘镜像校验通过、应用/辅助程序签名完整性通过。签名为 ad-hoc，Gatekeeper 拒绝，无公证票据，因此 **没有通过默认打开验证**。

- 本机只读信任报告：`macos-arm64-trust.json`。
- GitHub macOS runner 同样结果：`ci-trust/macos-arm64.json`。
- [独立系统信任核查 35753839436](https://github.com/Atingaii/Velo/actions/runs/35753839436)：failure，原因为上述实际分发限制；上传报告成功，不是脚本/下载错误。
- [常规 CI 35753838637](https://github.com/Atingaii/Velo/actions/runs/35753838637)：macOS、Windows、browser 全部 success，源码 656adab。
- `local-installed-smoke.json`：从公共 DMG 复制后的二进制，在显式隔离 smoke 模式下启动原生设置 WebView、Rust IPC、helper 通过，未启动供应商采集。

没有关闭 Gatekeeper、删除 quarantine、替换用户安装或修改用户凭据。直接启动 smoke 不模拟首次信任操作，不代表完整账户功能验收。当前没有产生新安装包，避免重新发布同样的未公证文件；现有 preview.4 发布说明已更新，并附 `trust-macos-arm64.json`。

## 用户路径

Mac 下载按钮保留真实 DMG 链接；点击后展开安装下一步。说明覆盖拖入应用程序、拦截时点完成、隐私与安全中对 Velo 选择仍要打开、确认后从菜单栏打开设置，以及未找到按钮、没有普通主窗口、升级后的常见情况。步骤参考 [Apple 官方文档](https://support.apple.com/zh-cn/102445)。必须由用户完成系统确认，不能宣称无提示安装。

## 官网验收

https://velo.codes 正式域名四页面（首页、产品说明、指南、下载）在 1440/390/320px 下无页面横向溢出、图像缺失或浏览器错误。导航当前页、主题跨页、截图放大/Escape/焦点恢复、手机原尺寸图片滚动、真实 DMG 下载及后续步骤、安装排障展开、旧 hash 跳转通过。浏览器实际下载 SHA-256 与公共包一致。

2x 截图直接渲染当前软件 HTML，保留产品原样式；五张截图覆盖用量、账户、外观、位置、通知。数据为现有 demo-bridge 的合成数据，非真实账号截图或原生系统截图。

本地 Node 13 项测试、4 页 UI 脚本检查、官网 JS 语法、5 个静态页面的本地资源/片段/重复 ID 校验通过。原生源码未修改，后续官网提交不重跑 native 构建；线上浏览器记录关联 e9119b2。

生产 Cloudflare Pages 部署：https://90478fc1.velo-5i0.pages.dev 。既有 release-preview 分支同步更新。
