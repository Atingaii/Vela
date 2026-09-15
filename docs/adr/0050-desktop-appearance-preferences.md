# ADR 0050 — 桌面外观偏好的严格本地 schema

日期：2026-09-16。状态：Accepted（仅确定 Core 持久化与校验边界；renderer 控件与视觉应用另行实现、验证）。

## 背景

桌面需要保存主题、信息密度和缩放偏好。将任意 renderer 字符串或数字直接写入现有 settings 记录，会破坏 `VelaPreferences` 对未知字段、JSON Boolean 与向后兼容读取的约束，也会令旧存储的无效值进入后续界面逻辑。

## 决策

继续使用 Core-owned `VelaPreferences` 和既有 `settings.get/settings.save` RPC；不新建 AppKit 或 renderer 专属偏好存储。

- `theme` 是 `system`、`light`、`dark` 之一，默认 `system`。
- `density` 是 `standard`、`compact` 之一，默认 `standard`。
- `zoomPercent` 是 90 至 150（含）的 JSON 整数，默认 100；接受数学上为整数的 JSON 数值（例如 `100.0`）并规范化为整数，拒绝 Boolean、非整数数值、非有限值和范围外值。

保存仍拒绝未知键，并与 locale、通知和审批有效期的既有 patch 合并。读取旧 settings 时，缺失或非法的三项分别回退其默认值，其余已知有效偏好保持不变。该 schema 不涉及窗口 frame、任意 CSS、任意文件路径、进程控制或网络同步。

保存会先取得原始 settings 对象并保留其中未知的已存储字段，再以 `VelaStore.putBatch` 的既有 snapshot hash 比较写入。比较与写入在同一 SQLite 写事务内：另一 helper 或进程在读取后更新该对象时，本次保存失败并要求基于最新状态重新发起；不会自动重试或静默覆盖对方的 patch。首个 settings 记录使用既有的 absence precondition。

## 后果与重新考虑条件

所有客户端使用相同 RPC 时会获得相同的规范化值；Core 测试可覆盖严格输入和重开 store 后的兼容读取。renderer 必须只将已确认的 schema 值映射到自身样式，不能把任意值回送给 Core。

renderer 的外观、语言和通用设置共用串行保存队列，只以完整的 confirmed response 更新已保存状态。延迟的读取不得覆盖较新的确认结果；离开设置页不会清除未提交草稿。该约束不替代 Core 的跨进程 CAS。

若需要每个项目单独的外观、辅助功能系统值映射或跨设备同步，再单独决定数据作用域和迁移；本 ADR 不授权这些扩展。

## English

Appearance preferences stay in the existing Core-owned settings record. Theme and density are strict enums, and zoom is an integer in the inclusive 90–150 range. Invalid saved legacy values repair independently to defaults on read; unknown save fields remain rejected. Saves preserve unknown stored fields and use the existing Store snapshot compare-and-swap, returning a conflict rather than retrying after a concurrent update. Renderer styling is outside this decision.
