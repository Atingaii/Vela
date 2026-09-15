# ADR 0032：持久化、受审的 Ask 路由

- 状态：Accepted；实现与验证分开记录
- 日期：2026-09-13

Ask 需要可解释的入口，但路由不能把问题自动变成模型调用、工作流或外部写入。因此 Core 先保存 `ask_route`：候选 ID/hash、scope、确定性理由及 `routeHash`；它只建议 `ask.create`、`workflows.plan` 或已有 workflow 的 `workflows.run`，不创建 query、plan、run、approval 或模型调用。

当用户选择进一步分类时，`ask.route.propose` 创建一个可预览的 `ask_route_proposal` 和既有 approval ledger。待用户对冻结快照明确批准，才以 `RestrictedCodexProposal` 的只读、禁用工具协议运行一次模型。模型只能从冻结的公开来源或启用 workflow 候选中选择 `knowledge_query`、`workflow_draft`、`reviewed_execution` 或具备 `agent.loop` 步骤的 `reviewed_agent_path`。approval/run 只保存 proposal ID 和 request hash；冻结 request 留在专用 proposal 记录。执行前再次核验 route hash、项目、scope、来源 hash/私有状态和 workflow 版本；任何变化都会在启动 provider 前失败。模型结果只持久化 proposal，绝不自动调用 query、planner、workflow 或 agent loop。

路由候选只来自当前项目的公开 Active Library、scope 匹配 Active Memory 和启用 workflow 元数据。私有、跨项目、无效 scope、私有资料路径、未知字段和 credential-like question 均拒绝。候选正文不写进 route/proposal；确定性词面评分和模型分类都是建议，不代表语义正确性。候选后来变私有、被删除或改变时，专用 route/proposal 读取只返回安全摘要；通用全局 Inbox 不列出 Ask approval，带项目范围的 Inbox 也只显示可决定所需的 ID/hash 摘要。

Ask question 可达 4,000 UTF-8 bytes，完整 question 独立冻结；持久化 title 只是最多 240 bytes 的 Unicode character-safe 展示截断，不能反过来拒绝合法 question。每类候选扫描最多 10,000 条当前项目记录；达到该界限即拒绝路由，不能把部分扫描表现为无候选或完整结果。新 route 使用 `routeHashVersion:2`，hash 覆盖 workflowCandidates；无该版本的旧记录仍可读取安全摘要，但不能创建新 proposal，用户须重新路由。proposal 创建前立即重验冻结候选，来源已经私有、删除、改变或 workflow 已变更时零 proposal/run/approval 写入且不返回 request；批准前仍再次重验。

该 ADR 仅闭合 PX0-085 的受审、无副作用 Ask 路由闭环，仍是局部能力：它不提供会话式 Ask UI、自动执行、会议/转录输入或无限制模型聊天。参见 [合同](../implementation/ask-routing-contract.md)、ADR 0021、0012 与 0020。
