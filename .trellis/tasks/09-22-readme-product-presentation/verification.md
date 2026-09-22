# 验证记录

- 修改范围：README、品牌/截图素材及截图复现文件；应用源码、图标、版本和依赖清单未修改。
- 头图：内置 imagegen 生成，1983 × 793 PNG；提示词保存在 `docs/assets/readme/assets.md`。
- 界面图片：当前 HTML + 显式模拟 IPC；350 × 470 用量卡片与 860 × 600 账户设置，页面 JS 错误为 0，已人工目视检查。
- Markdown：GitHub Markdown API 成功渲染；本地相对链接与图片全部存在，致谢只出现在文末。
- 排版：GitHub 渲染 HTML 配以近似 Markdown 样式，在 1100px 和 390px 浏览器中检查；页面 scrollWidth 分别为 1100/390，全部三张本地图片加载成功。此项不是 GitHub 网站全页实测。
- `npm run check:ui`：4 页通过。
- `npm test`：10 项通过。
- Playwright：使用仓库 17 个既有场景、单 worker、本机 Chrome，全数通过；临时配置仅切换 channel 和使用本次已启动的预览服务。
- `git diff --check`、Trellis 上下文检查通过。
- 纯文档任务未执行 Rust 构建、打包、双平台原生或真实账户测试，也未发布安装包。
- Spec review：无新增运行时协议或工程决策；演示素材来源和复现方法归档在配图说明，不改现有产品规范。
- 用户已明确授权提交并推送 main，无需另行确认。没有创建远程 Issue 或 PR。
