# 提醒事件契约

## 1. 范围 / 触发

固定 Swift 主线 `AppDelegate.announceCompletions`、`NotchWindowController.peek/showResetAlert` 与 `UsageResetCard` 的迁移；后端来源为 `src-tauri/src/notifications.rs`，接收方为 `src-tauri/ui/notch.html`。

## 2. 签名

- `notch_alert`：Rust emit → HTML listener。
- `preview_notch_alert(kind: String) -> Result<(), String>`。
- `focus_session(id: String) -> bool`：仅存在且可定位的会话返回成功；不存在的 ID 不回退到其他应用。

## 3. 契约

载荷 `{provider, provider_name, kind, label, seconds, session_id, resets_at}`；`resets_at` 为可空 Unix 毫秒，`session_id` 为可空稳定 ID。

- `done/attention` 只临时展开，不能主动打开或替换额度卡片；会话时长来自设置，点击接续的有效期延长 2 秒。
- `reset` 显示独立额度卡片 5 秒，`sessionLimitReached/weeklyLimitReached` 显示 6 秒。用量提醒与展开分别计时，后到的完成提醒不能提前关闭额度卡片。
- 同一批完成事件仅取最近活动的会话，不排队、不连续播放多个声音。首次快照和会话消失不等于完成。
- Claude hooks 与其他供应商活动共用转换器，以 `(provider, session ID)` 保存上一状态；busy → waiting 为 attention，busy → success/idle 为 done。读取快照与更新转换器在同一互斥区间，避免并发发布旧状态倒流；发送声音/事件在锁外。停用账户从观察集合移除，不触发完成。
- 隐藏刘海时不强制展示。真实额度事件回退系统通知；权限在需要送达时请求。

## 4. 验证 / 错误矩阵

| 条件 | 行为 |
| --- | --- |
| 未知预览类型 | 返回错误，不播放声音 |
| 系统通知权限拒绝 | 不发送，不伪装成功 |
| 已过期或不存在的目标 | 不跳到无关会话或 Claude Desktop |
| 重复相同完成快照 | 不再次提醒 |

## 5. Good / Base / Bad

Good：额度卡片显示期间完成事件到达，卡片保持原内容与到期时间。
Base：点击关闭额度卡片后，悬浮恢复普通用量卡片。
Bad：把完成提示叠加到普通用量卡片，或把所有事件复用为同一计时器。

## 6. 必需测试

Rust：同时完成按活动时间排序、首次加载静默、重复事件不重播、会话消失不报完成、不同账户同会话 ID 不串状态。
Playwright：独立卡片内容/高度、关闭、完成只展开、事件重叠、点击携带稳定会话 ID 且不触发用量刷新。
原生验证：macOS / Windows 权限、声音、真实终端定位分别记录，浏览器 mock 不算原生通过。

## 7. Wrong / Correct

Wrong：`notchAlert = event` 对所有 kind 通用，并以完成提醒的短计时取消额度卡片。
Correct：只有额度 kind 改变 `notchAlert`；`alertTimer` 与 `peekTimer` 分别管理卡片和展开。
