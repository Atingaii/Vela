# 架构决策记录

状态：Accepted 表示本轮采用；不代表所有平台已完成实机验收。

1. [ADR-0001：保留交互，迁移 Tauri 2](0001-cross-platform.md)
2. [ADR-0002：设置收敛与按需工具窗口](0002-settings.md)
3. [ADR-0003：可显式启停的边缘插件](0003-plugins.md)
4. [ADR-0004：本地账本、估计与数据边界](0004-usage.md)
5. [ADR-0005：多 CLI 配置适配与可恢复写入](0005-cli-sync.md)

6. [ADR-0006：全量迁移与 UI 一致性优先，插件随后](0006-full-swift-parity-before-product-changes.md)

当前交付顺序以 ADR-0006 和用户最新范围为准；ADR-0002、0004、0005 的产品扩展暂缓。

7. [ADR-0007：Velo 品牌与可验证的预览发行](0007-velo-preview-distribution.md)
8. [ADR-0008：独立预览更新索引与应用包签名](0008-signed-preview-updates.md)
9. [ADR-0009：先完成 macOS，其他平台等待明确启动](0009-macos-first-delivery.md)

当前平台实施和发行范围由 ADR-0009 收敛为 macOS；ADR-0006 的完整迁移标准继续适用。
