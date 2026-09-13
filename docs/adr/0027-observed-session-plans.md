# ADR 0027：依据持久化工具回执观察会话计划

- 状态：Accepted；兼容与验收范围分别记录
- 日期：2026-09-13
- 范围：Blume B12；不包含子代理、PTY 或 Cursor 格式扩展

## 背景与公开证据

会话正文中的“完成”和会话结束不是 Todo 的持久化状态。Codex `update_plan` 调用也可能失败；Claude `TaskCreate` 的任务 ID 直到回执才确定。仅从调用参数投影已完成，会把提议和实际工具结果混为一谈。

本轮固定核对 Codex `rust-v0.114.0` 的 [参数类型](https://github.com/openai/codex/blob/rust-v0.114.0/codex-rs/protocol/src/plan_tool.rs)、[处理器](https://github.com/openai/codex/blob/rust-v0.114.0/codex-rs/core/src/tools/handlers/plan.rs) 和 [持久化策略](https://github.com/openai/codex/blob/rust-v0.114.0/codex-rs/core/src/rollout/policy.rs)。工具调用与结果保存在 rollout，`PlanUpdate` 事件不保存；当前固定 revision [a4c61aff](https://github.com/openai/codex/blob/a4c61afff27b954e3c0831c728f11f8f9a17ae73/codex-rs/rollout/src/policy.rs) 仍如此。历史 JSON 中的 `output` 是文本/内容数组，内部 `success` 元字段不序列化。因此主路径配对 `call_id`，要求已知精确成功回执，而不等待一个不存在的 `success:true` 字段。

Claude 的 [TypeScript 工具输入输出](https://code.claude.com/docs/en/agent-sdk/typescript) 与 [Todo 跟踪说明](https://code.claude.com/docs/en/agent-sdk/todo-tracking) 覆盖 TodoWrite、TaskCreate、TaskUpdate、TaskGet、TaskList。官方 [Python SDK parser 固定 revision](https://github.com/anthropics/claude-agent-sdk-python/blob/37a52c9fb3f0271de017911914b0d42efea6267e/src/claude_agent_sdk/_internal/message_parser.py) 读取 `tool_use_result`。公开仓库未确认本地 transcript 的 camelCase `toolUseResult` 合同，所以本轮不能把该字段宣称为官方等价别名。[Python 参考](https://code.claude.com/docs/en/agent-sdk/python) 对 TodoWrite 的输出说明与 TypeScript 不同；只有 `message/stats` 的结果不包含可核验任务数组，保留 unknown。

## 决策

新增纯 `SessionPlanProjection` reducer 与只读 `SessionPlanService`，由 SessionEngine 原本有界 JSONL 摄取驱动；不创建 provider 进程、不写 provider 文件、不调用模型。关联账本独立存为 `session_plan`，与 session 摘要及摄取 cursor 同一 `putBatch` 提交，联合核对三个原对象 hash/缺失状态，避免不同 helper 的旧快照覆盖较新提交。Dashboard 只获得小型计数摘要；会话详情和显式只读 API 返回当前已确认条目与有界事件页。History 原始分块、epoch 和分页合同不变，不自动全量回填。

`proposed` 只记录待确认调用；匹配成功结果才形成 `confirmed` 修订。明确错误记录 `failed`；结构未知、错误标记类型不符、重复 call ID、多结果共享一个无 ID 输出、缺失来源项目等情况为 `unknown`。失败和未知不能覆盖最后已确认状态；缺少已确认数组时 total/counts 为 null。未知条目状态保留 `sourceStatus`，标准化为 unknown，不能算完成。

Codex 以同一 `call_id` 的精确成功文本/已知内容块确认完整数组。Claude TodoWrite 使用结果 `newTodos`，不强制用输入覆盖修复后的结果；TaskCreate 使用结果分配的 ID；TaskUpdate 必须 `success:true`、匹配 taskId，并仅应用 `updatedFields` 证明的字段，状态额外要求 `statusChange.from/to` 与当前基线/调用一致。TaskGet 合并一项、null 不删除；TaskList 是替换整个集合的快照。TaskUpdate 删除保留明确 deleted 状态。

每个事件保留 provider/source ID、声明的 provider version、decoder revision、来源 byte offset/length、实际原记录 SHA-256 和配对调用引用。来源声明版本不等于所有版本已经实测。项目改变清除旧内容与相关调用；普通消息、session Completed、背景任务通知均不产生 Todo 状态。

## 有界行为与权衡

最多 256 条当前任务、64 KiB 当前内容、16 个且合计 256 KiB 待确认调用、128 个事件摘要；超界明确标记，不扩大默认消息窗口。事件仅存状态和引用，不复制每次完整数组；完整原文可由单独历史回填保留。完整集合、全部历史覆盖、来源活性和工程工作验证是不同概念；即使 complete 数量等于 total，也只证明 provider 曾确认这些任务状态。

默认尾窗可能缺少调用或基线，因此会缺省为 unavailable/unknown，用户后续完整历史投影需要单独接入。来源等长重写或截断触发重建，单批读前后核对文件版本；增量观察不声称跨所有历史字节的内容一致快照。保持默认轻量比扩大窗口更可维护，但不能用此切片关闭 B12 的全版本/完整历史/UI 验收。

## English summary

Plan progress is a read-only projection of matched, persisted provider tool acknowledgements. Proposed calls, failures, unknown formats, deleted tasks and confirmed revisions remain distinct. A separate bounded ledger stores provenance without expanding dashboard payloads. Confirmed task status is not proof of successful engineering work. Full-history projection and undocumented Claude transcript variants remain explicit compatibility work.
