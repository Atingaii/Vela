# ADR 0045：有界待审批有效期与终态账本

- 状态：Accepted（开发分支；桌面专用设置与完整产品验收另行推进）
- 日期：2026-09-14

## 背景与选择

Vela 的审批冻结了工具、参数、项目、run 与 step，但过去的 `pending` 记录没有有效期。长期未处理的待审批请求不应在很久以后仍可启动外部动作，同时已开始执行或结果不确定的记录绝不能被清理或重写成安全的终态。

本提案只规定新审批的创建、读取、认领与终态展示；不引入删除、自动保留清理、UI 或后台扫表服务。Core 从本地 `settings` 读取 `approvalExpirySeconds`：默认 `604800`（7 天），`0` 明确关闭新记录过期，正整数范围为 `1...31536000`（最多 365 天）。设置值以数值上为整数的 JSON number 验证（`1` 与 `1.0` 同义），拒绝布尔、分数、负数与超界值。真实 CLI 可仅通过公开 `settings.save` 写入短 TTL 用于隔离验收；时钟注入仅限 Core 测试构造器，不是 RPC 参数。

启用有效期时，新 pending 记录写入 `expiresAt`；关闭时写入 `expiryMode: disabled`。统一 factory 覆盖 workflow 步骤、Lab、Knowledge/Ask、Replay、Agent Loop、Workflow Planning、Model Improvement 与 Connector 创建面。`expiresAt` 不进入既有 frozen 参数哈希：它控制何时仍可认领，不改变已经审阅的工具调用。

旧 pending 记录缺少 `expiresAt` 时保持 `legacy_unbounded`。不追溯写入、不假定历史创建时使用了任何默认值，且不因升级改变其可执行性。读取视图明确标识该兼容状态。

## 原子状态转换

审批决定在 SQLite `BEGIN IMMEDIATE` 已成功之后才读取当前时钟和审批行。若仍为 `pending` 且截止时刻已到，事务将审批、关联 run、关联 step 与专用 owner（eval/query/proposal/replay/loop/plan/improvement/connector action）一起标记 `expired`，不执行工具；事务提交后 `approvals.decide` 返回明确错误，而不是决定成功 JSON，避免旧 renderer 把它错误显示为已批准。等待写锁期间跨过截止时刻的调用因此不会复用排队前的时间而获批。

只有 `pending` 能过期。`executing`、`needs_review`、`acknowledged` 和所有其它已终态不被改写：执行过的副作用或不确定结果必须继续可审计。正常批准继续沿用现有 frozen 参数、来源与内存资格复核；普通 Memory 正文编辑不替换 frozen argv/hash。拒绝继续是显式用户决定，不等同到期。

`approvals.get` 返回单条审批记录；`approvals.list` 以 `createdAt ASC, id ASC` keyset 分页并可按状态过滤，默认 `pending`。这两个 Core/CLI RPC 入口可能把已到期的 pending 原子投影为 `expired`，然后返回结果；它们不执行工具，尚未声明 renderer 接入。`expired` 列表每次最多投影 200 个实际已经到期且有 `expiresAt` 的 pending，并返回明确的 bounded projection 说明；legacy 或 disabled 前缀不会遮住这些候选。列表/读取没有删除任何记录。

## 终态与保留边界

`expired` 是“没有开始执行且审批时间已过”的独立终态，不计入 workflow health 的成功或失败分母；health 单独报告过期 run/approval。组合运行将已过期 child 作为终态继续传播，而不会重新启动 child。专用 owner 视图同步显示 `expired`，避免仍把不可执行请求呈现为 pending。

本提案不选择 resolved-record retention 天数，也不清理 source、run、undo、审计或审批正文。未来的保留策略必须单独决定：保留期到达后如何防止悬空 owner/source、如何保持 undo 与 hash 审计，以及如何在不删除 `needs_review` 的情况下分页管理终态记录。

## 验收

必须证明：九个创建面都通过 factory 写入默认/禁用 policy；短 TTL 在真实公开 CLI settings 下使 workflow approve 变为 `expired` 且零副作用；写锁等待跨截止时刻也到期；旧 helper 产生的缺字段 pending 在新 helper 下保持 unbounded；并发决策只有一个认领或到期终态；关联 owner/run/step、composition 与 health 反映终态；`get/list` oldest-first、过滤与 cursor 严格验证。执行中或 uncertain 记录不得因时间流逝变为 expired。

## English summary

New approvals default to a seven-day local TTL, configurable as a validated integer policy. Legacy pending records without `expiresAt` remain explicitly unbounded. The deadline is evaluated only inside the SQLite claim transaction; expiry atomically marks the approval and its linked owner/run/step terminal without executing a tool. This decision preserves executing and uncertain ledgers, provides oldest-first pagination with bounded lifecycle projection, and deliberately defers deletion/retention policy.
