# 用量与账户元数据

## 1. 范围 / 触发

供应商解析 → `UsageSnapshot` → 持久缓存 / WebView / Phone Link v3。固定 Swift `UsageModel`、`KimiUsage`、`GitHubCopilotUsage`、`MiniMaxUsage` 为契约来源。

## 2. 签名

- `UsageSnapshot.plan: Option<String>`。
- `LimitWindow.remaining / used_count: Option<i64>`。
- `providers::parse::reading(id, &Value) -> Result<UsageSnapshot, Failure>` 保留解析出的窗口与套餐，采集线程统一写入成功状态和采集时间。
- `phone_link::provider_json(id, label, snapshot, headline)` 为纯协议投影。

## 3. 契约

`count: Some(n)` 表示无分母的计数，不能再把 `used` 当百分比；`remaining` 表示供应商报告剩余量，`used_count` 表示已用量，可与百分比同时存在。Phone Link 映射为 `usedFraction / remaining / used`，未知字段显式 `null`，禁止用零填充。套餐名通过 `account.plan` 传输；源为 Vela，未知套餐 `account:null`。

新字段均 `serde(default)`，旧缓存可读取。失败沿用旧快照及其时间；有缓存的 backoff 对手机呈现 `stale`，无缓存为错误。套餐名称经文本转义展示为卡片副标题。

## 4. 验证 / 错误矩阵

| 输入 | 输出 |
| --- | --- |
| Kimi `TIME_UNIT_MINUTE:300` | `rolling`，duration=18000 秒 |
| Kimi 未知窗口 / 缺 used | 不虚构该窗口 |
| Copilot 仅 remaining、无 entitlement | 无百分比，remaining 保留，used=null |
| Copilot used 与 remaining 同在但无 entitlement | 使用 used，不把 remaining 当已用 |
| MiniMax 百分比 + boost permill | 保留百分比，并按上游规则计算可解释的计数 |
| MiniMax 百分比但无 boost | 不推测计数 |

## 5. Good / Base / Bad

Good：75 次剩余额度显示“75 left”，不画 0% 进度条。
Base：25% 使用率、50 次已用、150 次剩余可以同时传输。
Bad：缺少上限时把剩余 75 次输出成 `used:75`，或靠显示标签反向解析套餐。

## 6. 必需测试

真实上游字段形状的离线解析测试；Kimi 未知窗口过滤；Copilot 剩余/已用方向；MiniMax boost；旧缓存兼容；手机显式 null / 原采集时间；浏览器副标题文本转义与无分母不画进度条。

## 7. Wrong / Correct

Wrong：采集仅返回 `Vec<LimitWindow>`，丢失套餐；手机固定 `account:null`。
Correct：解析携带 `UsageSnapshot.plan` 到缓存和事件，桌面与手机消费同一字段。
