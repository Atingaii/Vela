# 前端验收

按顺序运行：

```sh
npm run check:ui
npm test
npm run test:ui
```

`npm test` 的 Node 测试并发为 1，Playwright 已配置 workers=1。不要和 Cargo 全量构建并行运行浏览器测试。验证设置读写失败、刷新状态、账户隔离和悬浮展开。保留 Codenotch 操作路径；功能迁移未完成时不得以精简界面删掉入口。
