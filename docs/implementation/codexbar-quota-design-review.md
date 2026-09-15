# CodexBar 额度展示：只读设计与数据映射审查

- 审查日期：2026-09-14
- 目的：借鉴可理解的“剩余额度 / 重置时间 / 新鲜度”呈现模式；不引入 CodexBar 的品牌、代码、认证读取或多 Provider 承诺。
- Vela 当前边界：仅 Codex，读取用户明确选择的本地 CLI 的只读 `account/rateLimits/read`；不会读取 token、账号、cookie、额度重置券或原始 stderr。

## 参考来源与归属

本轮只读参考的上游是 [steipete/CodexBar](https://github.com/steipete/CodexBar)，固定到 commit [`86a47f80a71e74c59dd2d4dd14de397348d36546`](https://github.com/steipete/CodexBar/tree/86a47f80a71e74c59dd2d4dd14de397348d36546)（2026-09-13）。它自述为多 Provider macOS 菜单栏额度工具；其 [Codex 数据路径说明](https://github.com/steipete/CodexBar/blob/86a47f80a71e74c59dd2d4dd14de397348d36546/docs/codex.md) 说明 OAuth、Web、CLI 等可选来源及其缓存/失效处理。

参考副本位于本仓库的 `.task-tmp/reference-codexbar-r1`，只作审计，未构建或执行。上游 [MIT License](https://github.com/steipete/CodexBar/blob/86a47f80a71e74c59dd2d4dd14de397348d36546/LICENSE) 版权归 Peter Steinberger。此审查没有复制任何源代码、图标、名称、商标、文案或认证实现；若将来确有逐行复用，必须另行保留 MIT 许可证和版权通知，并完成独立安全审查。

## 可借鉴的产品模式，而非实现移植

CodexBar 的核心可借鉴点是把每个真实窗口分开呈现：剩余百分比、窗口长度、下一次重置、最近成功读数和新鲜度。它也把“没有可信读数”与“剩余 0%”分开，并在异常或可疑重置时不把缓存伪装成新读数。其 `RateWindow` 模型保留 `usedPercent`、`windowMinutes`、`resetsAt`，并由展示层计算 remaining；`UsageSnapshot` 同时保留多个命名窗口及 `updatedAt`（参考副本 `Sources/CodexBarCore/UsageFetcher.swift:3-170`）。

Vela 可以借鉴这一信息层次，但不采用其 OAuth/auth.json、WebView/cookie、账号切换、额度券、价格、自动多 Provider 探测或长期缓存策略。那些路径扩大了凭据和网络边界，也超出 Vela 已声明的功能范围。

## Vela 已有数据合同

`ProviderQuotaService` 已提供足以支持单 Provider 额度卡的规范化数据：

| 视觉字段 | Vela 实际字段 | 语义与限制 |
| --- | --- | --- |
| Provider | 固定 `provider: "codex"` | 当前只接受 Codex；其他 provider 直接拒绝，不能在界面中虚构多 Provider。 |
| bucket 标题 | `buckets[].limitName`、`limitId` 或 `key` | 保留 CLI 返回的来源标识；未知 ID 不命名为套餐。 |
| 窗口 | `buckets[].windows[]` 的 `name`（`primary` / `secondary`） | 不存在的窗口不补造。 |
| 剩余 / 已用 | `remainingPercent` / `usedPercent` | `remainingPercent = clamp(100 - usedPercent)`；数值缺失必须显示未知，而不是 0%。 |
| 窗口长度 | `windowDurationMins` | 缺失时显示“未提供”，不猜测“5 小时/每周”。 |
| 重置 | `resetsAt`（Unix 秒） | 仅有该字段才显示绝对时间或倒计时；已经过期的窗口不构成可用额度。 |
| 新鲜度 | `status`、`sourceCapturedAt`、`ageSeconds` | `fresh`、`stale`、`error`、`never_read` 是状态，不能被百分比替代。 |
| 最近一次读取 | `lastAttemptAt`、`lastAttempt.succeeded`、安全的 `error.kind` | 最近尝试失败时仍可保留旧成功快照，但必须标 stale/error 且 `quotaAvailable=false`。 |

数据入口是 `usage.quota.status`（只读本地最后结果）和用户明确触发的 `usage.quota.read`；后者只接受绝对 `executable` 路径。规范化实现见 `Sources/VelaCore/ProviderQuotaService.swift:20-107`，短命受限 app-server 传输见同文件 `:110-245`，bridge allowlist 在 `Sources/VelaApp/main.swift:1605`。现有 renderer 已渲染 bucket、窗口、剩余、重置、最近成功/尝试与状态标签：`Sources/VelaApp/Resources/UI/app.js:15938-16091`。架构与安全边界由 [ADR 0011](../adr/0011-provider-quota-observation.md) 固定。

## 推荐的呈现映射

1. 在 Usage 的 Codex 区域按 `bucket` 分卡；卡内按 `primary`、`secondary` 排列真实窗口。每行首要信息为“剩余 %”，次要信息依次为窗口长度、重置时刻、已用 %。这与当前数据和当前 renderer 结构一致。
2. 把 `status` 和 `sourceCapturedAt` 固定放在区块标题附近：`fresh` 才可使用常规状态色；`stale` 必须连同“上次成功读取”显示；`error` 显示安全错误种类；`never_read` 只提供用户触发读取的路径。旧百分比仍可作为历史观察，但不能带“当前可用”暗示。
3. 倒计时仅是 `resetsAt` 的本地展示投影：缺字段、非法字段、过期窗口或 stale/error 时不估算新的 reset。没有 `windowDurationMins` 时同样不推导循环周期。
4. 视觉上可借鉴紧凑的进度条和分层详情，但应使用 Vela 自己的颜色、图标、中文/英文文案与本地化键；不复制 CodexBar 菜单栏图标、命名、Provider 切换器或图形资产。

## 明确不应被误报为已实现

- Vela 不是 CodexBar 的多 Provider 额度监视器；Claude、Cursor 和其他个人订阅额度仍未实现。
- Vela 没有读取 `auth.json`、cookie、账号邮箱、网页仪表盘、reset credits、价格/成本、账户切换或自动后台刷新。现有按钮是用户选择本地 Codex CLI 后的只读刷新。
- Vela 没有来自本地日志 token 到订阅额度的换算；两类数据继续分离。
- “Unavailable / stale”是观察可信度，不是额度耗尽，也不应触发 `usage_reset` 自动化。后者在当前自动化合同中仍不可用。

## 后续实现验收点（供独立 UI 作者与测试者使用）

任何视觉调整都应对同一冻结的 `usage.quota.status` 数据检查：多 bucket / 双窗口、已知 0%、缺少百分比、缺少 reset、stale 的旧成功快照、失败的最近尝试以及 never-read。验收需证明每一种状态不会显示为新鲜的 0% 或编造重置时间，并继续验证 renderer 不传入 executable 之外的任意 CLI 参数。多 Provider、凭据读取、Web 数据源或自动刷新另需独立产品决策和 ADR，不能随样式调整顺带接入。
