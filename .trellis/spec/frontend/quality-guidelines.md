# 前端验收

按顺序运行：

```sh
npm run check:ui
npm test
npm run test:ui
```

`npm test` 的 Node 测试并发为 1，Playwright 已配置 workers=1。不要和 Cargo 全量构建并行运行浏览器测试。验证设置读写失败、刷新状态、账户隔离和悬浮展开。保留 Codenotch 操作路径；功能迁移未完成时不得以精简界面删掉入口。

透明桌面窗口的修改增加 `VELO_WEBKIT=1 npm run test:ui`，并以原生 WKWebView 检查截图。供应商标记必须使用实际内置资源验证，不得仅依赖测试用 SVG。六账户、四边、收起/展开、两端弧线和手柄均需覆盖；窗口初始常量不能作为实际内容不被裁切的验收证据。
