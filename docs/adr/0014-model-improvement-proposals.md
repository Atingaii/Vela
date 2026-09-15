# ADR 0014：以冻结证据生成模型式 Improve 提案

- 状态：Accepted（Core 接口采用；真实模型质量、前端和后续改善验收另列）
- 日期：2026-09-13
- 范围：手动多阶段分析、来源与目标快照、候选生命周期、共享受限 Codex 协议

## 背景

Blume 已公开交付的 Improve beta 包括语义分析、跨会话归并、模型规划和证据审阅。Vela 的确定性工程纠错与工具序列检测有可测边界，但不能替代模型理解，也不能把同名页面算作完整功能。

直接让模型遍历用户项目或所有历史会扩大输入范围；直接执行模型给出的路径或命令会混淆建议与授权。将所有阶段合为无结构长回答则难以核验引用与错误发生点。

## 决策

保留 `improve.analyze`，新增独立 `model_improvement` 对象和 `improve.model.plan/describe/list/get/transition`。用户必须明确项目、1–20 个已索引 session ID、1–5 个 `{carrier,path}` 目标、Codex executable/model。默认和当前唯一触发方式为手动。没有隐式后台模型调用、云 fallback、自动审批或自动晋升。

创建请求只读同项目、非内部、非私密、受支持来源会话。隐私字段缺失或明确 false 才可用，错误类型不能默认为公开。Private Library 不在数据读取路径中。每条证据保留实际 session/message ID、provider source identity、原文 hash、来源 timestamp 和脱敏片段；不将模型解释写成新的事实来源。选择窗口、字节预算、遗漏数和历史局限在请求中明确可见。

来源对象 hash、证据、目标原文/baseHash、agent 选择、命令模板、三个 output schema 和预算被一次冻结。目标只允许现有 SafeApply context artifact 路径；旧内容若命中凭据模式则拒绝规划，不能将脱敏占位写回原文件。创建 plan/run/approval 使用同一事务及来源版本比较。审批复用既有一次性 hash/CAS 领取机制。

批准后最多调用三次选定 CLI，顺序为 extraction → cluster → planning：

1. extraction 只可引用冻结 evidence ID，生成观察假设。
2. cluster 只可引用前一阶段 observation ID，提出载体与分组理由。
3. planning 只可引用前一阶段 cluster ID 和原定 target ID，生成完整候选替换内容。

每阶段调用前和最终发布前重新核验源与目标，最终候选事务再比较来源完整对象 hash。模型不能增加路径、读取范围、工具或审批。任何阶段协议失败、输出超限、错误引用或数据变化都会停止；已发生的调用不会自动重试。输入不是可执行指令，输出不是成功证据。

与 Workflow Planning 共用 `RestrictedCodexProposal`：固定的受限 Codex exec flags、完整 JSONL 单答检查、禁止工具事件、0700 独立临时 cwd、0600 schema、结束后清理。各模块保留自己的 schema 和业务核验，没有新增 agent framework。Codex 0.154.0 在显式禁用 Code Mode host 时会给出特定 fail-closed error item；仅对逐字匹配、严格字段集合的这一个诊断记录 warning，其他 error/tool/失败 turn 仍拒绝。限制参数不因此移除。

硬边界为三个 provider 请求、每次 1–300 秒、prompt 最多 64 KB、协议输出 256 KB、单答案 32 KB、单候选 16 KB。实际 token 只来自完成的 provider 协议；`providerAttempts`、`completedModelCalls` 与失败时可能为 null 的 `modelCalls` 分开。`requestedModel` 是用户选择，`observedModel` 未被协议证明时为 null。这不是美元硬上限。

## 候选与生效

Rule 至少需要三个不同且未截断的用户证据，跨两个独立 provider source session；Skill/Hook/Workflow 至少三个 source session。复制或轮转同一 provider 日志不能增加独立性。一条抱怨最多成为观察，不能产生永久规则。门槛达到也只生成未验证候选，仍不证明模型语义正确或未来任务改善。

候选载体为 Rule、Skill、Hook、Doc、Workflow，包含 `operations`、SafeApply preview、原证据、模型解释及 `claimStatus:unverified_proposal`。Workflow 内容通过同一受限 workflow schema 构建停用 draft，另行保存/运行；Hook 需要 provider 自己的信任，不绕过 `/hooks`。

模型不调用 Apply。用户对模型候选 Apply 必须提交当前 `project` 与 `suggestionHash`，随后复查所引消息的内容、身份与隐私；允许引用之外的新消息追加。实际写入/Undo 继续使用现有文件身份、baseHash 和恢复日志。确定性旧候选接口保持兼容。

Snooze/Dismiss/Reopen 带当前 hash，通过 `putBatch(expecting:)` 防止并发覆盖。已应用候选不能通过这些转换隐藏 Undo。Snooze 到期不会唤醒模型；到期展示与自动触发策略是后续显式设置范围。

## 取舍和未关闭项

选择三次有界调用可以保存阶段责任、引用边界和失败位置，但比单次回答有更多启动成本。最初仅接已核验的 Codex 协议；Claude/Cursor connected plans、create/update/remove 中的删除规划、全局作用域、空闲与额度末段调度、用户修订再冻结、模型输出的实际改善和完整 UI 仍是对齐清单中的工作，不能从这个 ADR 推导完成。

当前候选是创建或替换显式目标文件；没有自动删除或任意代码写入路径。敏感模式脱敏是有界防护，不是检测所有秘密的保证，因此用户仍能审阅精确的冻结输入。真实模型试跑必须独立记录选择模型、实际协议、用量来源、成功与失败；合成 fixture 的 token 不能当成服务费用。

## 验证与依据

- [Blume Improve 公开说明](https://blume.codes/blog/how-blume-codebase-improvements-work)
- [Codex app-server / CLI 文档](https://developers.openai.com/codex/cli/reference)
- [ADR 0012](0012-reviewed-workflow-planning.md)：共用的选择模型、受限命令与审批边界。
- [ModelImprovementTests](../../Tests/VelaCoreTests/ModelImprovementTests.swift)：实际隔离进程、三阶段、五载体、单次抱怨、复制来源、隐私、错误引用/工具/超限、冻结审批、独立 Apply/Undo、状态及 stale hash。
- [RestrictedCodexProposalTests](../../Tests/VelaCoreTests/RestrictedCodexProposalTests.swift)：严格诊断例外和拒绝边界。
- [CLI 回归脚本](../../scripts/test-model-improvement-rpc.py)：冻结真实 helper，合成 provider，完整审批→提案→Apply/Undo→重放拒绝。
- [显式真实 provider 脚本](../../scripts/verify-model-improvement-live.py) `--live --executable /absolute/path/to/codex`：只使用三份合成来源；一次审批最多三请求，不自动 Apply。脚本没有用户机器路径默认值，相对路径会在启动前拒绝。2026-09-13 的首轮已通过协议、原引用和候选链，结果见 Blume 台账；这不等于真实任务质量改善。不要从 CI 或无明确运行授权的后台启动此脚本。
- [UI/API 合同](../implementation/model-improvement-contract.md)、[Blume 全量台账](../parity/blume.md)。

## English summary

Model Improve is a separate manual proposal pipeline over explicitly selected, frozen project evidence and artifact targets. Three restricted Codex calls extract observations, cluster them, and plan reviewable changes. Closed schemas, source hashes, privacy checks and independent-evidence gates keep model hypotheses separate from facts and adoption. Apply requires a fresh reviewed suggestion hash and uses existing SafeApply/Undo. Shared transport avoids a new agent framework. Other providers, background policies, deletion planning and demonstrated improvement remain open.
