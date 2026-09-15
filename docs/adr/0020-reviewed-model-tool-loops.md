# ADR 0020：受审阅的多轮模型工具调用

- 状态：Accepted；真实 provider 联调与界面验收单独记录
- 日期：2026-09-13
- 范围：多轮模型决策、真实工具结果反馈、逐写审批、运行与预算证据

固定步骤与 pipeline 不能满足 [px0 tool loop](https://docs.px0.ai/tools/catalogue) 和[写动作排队后继续产出](https://docs.px0.ai/approvals/overview)的能力。Vela 使用用户明确选择的现有 Codex CLI，每轮通过已有 `RestrictedCodexProposal` 协议返回 JSON 决策。模型进程本身禁用 shell、MCP、apps、browser、plugins 等工具；Core 执行冻结目录中的明确能力。这个模块是已有 CLI 与运行账本之间的受限适配，不引入新的 Agent 框架或托管服务。

初始审批冻结 prompt、上下文来源、executable/model/effort、目录/schema/版本、命令模板和最大模型调用次数/单次及总时限。每轮先保存 claimed 记录，再启动独立干净 scratch，要求一个完整 JSON 答案和零原生 tool call。工具结果作为不可信数据反馈下一轮，不能改变目录或获得 executable 参数。只读 Git、Memory Recall、公开 Library 读取在 Core 执行并保留来源/hash；每次模型出站前重新检查来源的 private、作用域与状态。

Composio 能力绑定用户选定的账户、具体版本、schema hash、credential generation。所有 Composio 调用仍创建独立 action/run/approval；模型得到 queued receipt，可以继续回答。最终产物附上尚未执行的真实 approval IDs，批准这些动作不重跑模型。内部 prepared-action helper 仅复用已核对的请求，renderer/RPC 不能直接调用；实际执行仍重新检查 generation、账户和 schema。

目录参数只接受明确支持的 JSON Schema 类型、对象/数组、required、enum 和简单大小/数值约束；无法检查的约束拒绝进入模型目录，保留通过独立审阅 connector action 使用该工具的入口。这不是完整 JSON Schema 2020-12 验证器，也不能用一个简单工具 fixture 推导所有连接器已可用。

`maxModelCalls` 与进程时限是硬上限。Codex CLI 未提供本模块可验证的每轮 token 预扣参数，因此 observedTokenBudget 只在获得真实 usage 后阻止下一轮；缺 usage 时不继续跨越该阈值，单轮仍可能超出观测阈值。费用没有可靠来源时为 unavailable。取消在轮次/工具边界停止新增工作；当前模型进程有既定超时，不声称即时强制取消。崩溃、部分协议、信号和超时保留 needs_review，不盲目重试模型或外部动作。

普通 `agent.run` argv 兼容原有行为。新增工作流 `agent.loop` 使用独立参数结构；只有显式 `promptMode:workflow_context` 和完整 prompt marker 才绑定冻结 context。Dry Run 沿用全链路 stub，不调用模型、连接器 metadata 或写工具。

## English

A frozen, bounded loop asks the user's existing Codex CLI for one structured decision per round. The CLI itself has no tools; Core mediates selected reads and returns real receipts. External calls always create separate frozen approvals, while the model may continue to a final answer that explicitly lists pending actions. Call-count and time limits are enforceable; token thresholds depend on measured provider usage and are not a strict prepaid token cap. Incomplete or uncertain calls are never automatically retried. This extends the existing runner without adding an agent framework.
