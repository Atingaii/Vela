# 官网导航与视觉验证

- 验证日期：2026-09-23（Asia/Shanghai）
- 官网：https://velo.codes
- 源码提交：`e508ac7`
- Cloudflare Pages 生产部署：`7d67af4c-804d-461a-bfc5-9d46679b6305`，状态 success。
- 预览：https://release-preview.velo-5i0.pages.dev

## 验证结果

首页、下载、使用指南在 1440 / 390 / 320px 下均无横向溢出、无缺失图片，每页一个 H1，导航指向实际页面。

悬停、键盘聚焦和移动端点击切换首屏示例正常；验证了生产 CSP 下进度条实际宽度。主题跨页持久化、FAQ 展开、当前页标识、跳到正文、旧 #download / #faq 跳转均通过。浏览器无 pageerror 或 console error。

PNG、ICO 和 Apple Touch Icon 引用已更新；ICO 包含 16 / 32 / 48px。官网图标资源与三个安装包公开链接返回成功。用户已打开的官网标签页已刷新并确认新导航和交互示意。

本地 `node --check website/app.js`、`npm run check:ui`（4 页）、`npm test`（10 项）通过。静态资源、片段锚点和重复 ID 校验通过。

截图与 browser-checks.json 来自正式域名。browser-check.js 是本次可复用浏览器验收代码，输出路径需预先创建；http-checks.json 记录公开链接响应。

## 验收边界

本轮只修改官网和介绍链接，未修改桌面应用或安装包，未重跑原生发行 CI。首屏为标注过的交互示意，使用静态示例数据；真实设置截图在指南中。既有 Preview 安装包及其签名、真实账号验收限制不因官网更新而改变。
