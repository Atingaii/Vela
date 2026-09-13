# 会话 Todo / Plan 观察合同

当前实现只读 Codex/Claude 已识别 JSONL 工具调用与回执，不读取真实 provider 进程状态，不调用模型，不修改原日志。决策与固定公开来源见 [ADR 0027](../adr/0027-observed-session-plans.md)。本轮不实现 UI；后续由指定 Antigravity 作者接入。

## API

| 方法 | 参数 | 返回 |
| --- | --- | --- |
| `sessions.plan.describe` | `{}` | providers、tools、decoder、预算、兼容限制 |
| `sessions.plan.get` | `{project,id}` | 当前已确认 items、counts、来源、coverage |
| `sessions.plan.events` | `{project,id,afterSequence?,limit?}` | 有界来源事件页、nextAfterSequence、oldestRetainedSequence、eventsTruncated |

project 必须绝对路径且已登记，id 是 `sessions.list` 返回的 Vela session ID。拒绝额外参数、跨项目、未注册项目和任意 path。`afterSequence` 默认 0，范围 0…9007199254740991；limit 默认 50，范围 1…100；布尔、浮点、字符串不当整数。事件物理顺序决定 sequence，不用缺失时间戳排序。

`sessions.get` 也附 `plan`，沿用会话详情原有本地访问权限；新显式接口必须项目参数。`sessions.list` / dashboard 仅 `planSummary`，不加载 pending input 与事件数组。CLI `vela call METHOD --params-stdin --home STORE` 可达；本轮不修改 native/MCP allowlist。

## 返回语义

- `available:false` → 未观察到已确认状态；`total/counts:null`，不是零任务。
- `available:true,items:[],total:0` → 有明确成功空快照。
- `items` 为最新确认的集合；条目包含 id、content、status、sourceStatus，及有来源的 activeForm/description/owner/dependencies。TodoWrite/Codex 的 `position-N` 是该快照的数组位置，不伪造跨修订稳定 provider ID。
- `counts` 分开 pending/in_progress/completed/unknown/deleted，total 排除 deleted；`workVerified:false` 恒定。
- `itemSetComplete:true` 仅表示最后完整数组/TaskList 加后续可关联更新；TaskGet/单项创建不证明整个任务集合完整。
- `pendingUpdates` 是尚待回执数量，不能纳入 completed。
- `confirmedRevision` 是本地观察到的成功修订数；来源重建可重新开始，事件 sequence 不作为跨 source epoch 稳定历史 cursor。
- `lastConfirmed.source` 和 events.source 给 byteOffset/byteLength/sha256/sourceIdentity/sourceVersion 及 callSource；是原文件记录引用，不是任意文件读取授权。
- `providerVersion` 是来源自行声明的版本，缺失为 null；`formatContract` / `decoderVersion` 是识别器合同，不表示所有声明版本已测试。
- `coverageLimited` 独立反映尾窗、关联/事件预算；`sourceCoverage` 明确是 bounded indexed JSONL observations，不能宣称完整历史。

事件 state 为 proposed / confirmed / failed / unknown / scope_changed，附工具、callId、sequence、来源、诊断。页只保留最多 128 条；afterSequence 早于保留窗口时必须读 `oldestRetainedSequence/eventsTruncated`，不能把返回页当完整审计链。普通正文和会话终态不影响任务条目。

## 已识别形状与限制

Codex：`response_item.function_call(name:update_plan,call_id,arguments)` 与同 ID `function_call_output`，成功 `output` 是精确 `Plan updated` 或单一 `input_text` 内容块。`event_msg.plan_update` 不冒充标准 rollout 持久化来源。

Claude：assistant `tool_use` → user `tool_result.tool_use_id` + 顶层 `tool_use_result`。TodoWrite 结果要 newTodos；TaskCreate 要 task.id/subject；TaskUpdate 要 success 真布尔、taskId、updatedFields，并核对 statusChange；TaskGet 要 task 对象；TaskList 要 tasks 数组。`is_error:true` / `success:false` 明确失败；数字布尔、无匹配回执、多结果对应单输出、缺基线保留 unknown。

官方 SDK 的 snake_case 输出合同已经核验；本地 transcript 的 `toolUseResult` 及 Python 文档的 message/stats-only TodoWrite 输出未被当成等价成功形状。Pi/OMP/Cursor 的 Todo 适配、完整 History→计划重放、长期来源保留与全部客户端 UI 仍待独立实现/验收。历史服务继续按自己的合同保存原始记录，不受此投影裁剪影响。

## 本轮实际验证

2026-09-13：新增 18 个 SessionPlan 测试连同 ProviderCompatibility、Foundation、UsageIntegrity，共 59 个实际 Core 测试方法通过 portable runner；这是同步断言兼容层，不是 XCTest。冻结源码摘要 `8d8b37c7f8dfab03e390199376dd4ca4299096cf2ec3caa6fab9338a838af1ac`，结束时源码一致。收据与日志：`output/parity/blume/session-plans-verified.json/.log`。覆盖匹配/错误/重复、空与未知、Task 生命周期、true/数字布尔、缺基线、作用域与身份切换、等长重写、重启、多 helper 提交、History 原文独立保留。

真实编译 helper 的五组合成 JSONL→CLI 验证也通过：跨请求进程恢复、原记录 SHA-256 重算、Claude 成功/失败状态更新、跨项目/额外 path/错误参数拒绝、刷新幂等和摘要隔离。收据 `output/parity/blume/session-plans-rpc-verified.json`，helper SHA-256 `3dd60c6dea13868ad2f5006152f6acaa417d493dc89516ef51301b0097628e1e`；2026-09-13T06:39:29Z…06:39:31Z。零 provider/model 调用，无真实用户素材；临时 helper/store/home/logs 已清理。仅证明这些公开合同合成样例经过真实 Vela helper，不能扩称真实 provider 全版本测试。

## English summary

The read-only session plan APIs expose confirmed provider task state, bounded provenance events and explicit coverage. Calls alone cannot update progress. Unknown formats and missing baselines remain unavailable; successful empty lists differ from missing data. The recent-session projection does not claim full-history or all-provider compatibility.
