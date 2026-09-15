# 模型工具循环合同 v1

状态：Core/fixture 与一次合成项目真实 Codex 多轮验证已通过；独立反例持续复核，真实 connector 账户与桌面验收另行记录。UI 仍须由 Antigravity CLI Gemini 3.8 Flash High 实现。

## 创建与审阅

`loops.describe {}` 返回 protocol、builtinTools 及 `connectorAccess:queued_approval_only`。

```json
{
  "project":"/registered/project",
  "prompt":"查看工作区变化，再给出一个简短总结",
  "agent":{"executable":"/absolute/path/to/codex","model":"USER_SELECTED_MODEL","reasoningEffort":"high"},
  "tools":["git.status","git.diff","memory.recall","library.retrieve"],
  "limits":{"maxModelCalls":4,"timeoutSeconds":60,"totalTimeoutSeconds":180,"observedTokenBudget":0}
}
```

传给 `loops.plan`，仅创建初始审批；未批准不运行模型。`agent` 三字段明确选择，不猜模型或修改用户 CLI。目录最多16项，prompt最多24KB，目录最多16KB。maxModelCalls 为1–12，timeoutSeconds为1–90，总时限1–300秒。observedTokenBudget为0表示不设置观测阈值；非零时，上一轮实际 usage 达到阈值或 usage 缺失就停止下一轮，不能呈现为严格 token 配额。

`tools` 可包含连接器绑定对象 `{toolSlug,version,catalogHash,connectedAccountId?}`。plan 显式读取所选工具及账户 metadata 并冻结，未执行工具。版本必须具体；未知或暂未支持的 schema 不进入模型目录。目录项的实际访问策略由 Core 决定，不能相信描述中的“read only”。

返回 loop 与初始 approval，继续使用 `approvals.decide`。该审批只授权冻结范围内的模型轮次和只读目录；外部动作有自己的新审批。

## 查询与取消

| 方法 | 参数 | 行为 |
| --- | --- | --- |
| `loops.list` | `{project}` | 本地摘要，不返回 prompt、工具内容或原始日志 |
| `loops.get` | `{project,id}` | 请求/schema、轮次证据、queuedActions、output、loopHash；纯读取 |
| `loops.cancel` | `{project,id,loopHash}` | 待审批时拒绝；运行时记录取消，在下一轮/工具前停止；不替用户执行或拒绝已排队的外部动作 |

state 包括 pending_approval、running_or_uncertain、completed、budget_exhausted、cancelled、failed、rejected、needs_review。`running_or_uncertain` 不是已验证 PID 存活。取消不能保证中断正在执行的单轮 CLI；该轮仍受已冻结超时限制。读取详情不重跑，当前无盲目 resume/retry。

每轮保存 promptHash、commandHash、真实进程退出码/终止信号/耗时/输出 hash、有限原始协议、决策和工具 receipt。模型只可返回 `{decision:{kind:"tool",toolId,arguments}}` 或 `{decision:{kind:"final",answer}}`。未知字段/能力/类型、非完整协议或实际 CLI tool call 都停止。

`queuedActions` 的每项带 actionId/runId/approvalId 和 executed:false。显示“待单独审批”，不能显示“已发送/已写入”。final 包含 Core 追加的明确未执行说明和真实 approval IDs；模型生成文字本身不构成外部执行证据。批准排队动作不会再次调用模型。排队使用初始已批准的 identity/schema 与本轮严格校验的参数，零额外 metadata 请求；`metadataCapturedAt` 表示目录的捕获时间，`currentAvailabilityVerified:false` 表示此时未重新确认可用性。真正批准该动作时仍检查账户、profile generation 和 schema；发生变化则拒绝而不替换审批。action 来源与其审批同事务落盘，详情可重建尚未保存到 loop 摘要的排队关系。`executed:false` 描述入队事件，`currentActionState` 才描述当前独立动作账本。

`modelAttempts` 是已持久化的尝试数；`processCallsObserved` 仅在进程返回后增加；`modelCalls` 在完整协议可证明前为 unavailable。usage/cost 缺失不可呈现为零。每次出站前重新读取 Library 资产并检查显式公开、private-origin、项目和状态；资产丢失或转私有立即停止。已冻结的公开内容不会被后来编辑的文本替换。

## 工作流调用

步骤可使用 `agent.loop`，arguments 为创建参数去掉 project。若工作流有 context，则显式设置 `promptMode:"workflow_context"` 和 `prompt:"{{vela.prompt}}"`；Core 绑定冻结 prompt/hash 与来源，原文不递归展开。普通 agent.run 完整兼容。

Dry Run 将 agent.loop 整步 stub，不调用模型或在线目录、不创建 loop/action/approval。Context 中原有允许的只读输入仍按既有 Dry Run 合同执行。

## English

The initial approval freezes the requested model, prompt, capability schemas and bounded call/time limits. Core executes selected reads and sends actual receipts into later decisions. Every external call is queued without new metadata requests for a separate approval, which revalidates the frozen account and schema. Progress reads are local, cancellation applies at boundaries, and uncertain calls are not retried. Library privacy and asset integrity are checked again before outbound prompts. One live synthetic Git task completed in two model turns; this does not validate real external accounts or the complete product.
