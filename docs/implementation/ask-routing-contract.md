# Ask routing contract

`ask.route` 接受登记 `project`、无凭据、最多 4,000 UTF-8 bytes 的 `question` 和可选 branch/worktree/task/sessionId，保存 `ask_route` 后返回 `routeHash`、可见候选 ID/hash、理由与 decision。完整 question 参与冻结；最多 240 bytes 的 title 是 Unicode character-safe 展示截断，不能使合法 question 失败。每类 Memory、Library、workflow 候选扫描最多 10,000 条当前项目记录；达到上限时请求明确失败，绝不把不完整扫描称为无候选或完整结果。`ask.route.get` 只在同项目读取；若冻结候选已私有、丢失或改变，返回不含候选的安全摘要和 `sourceValidation:"unavailable"`。

`ask.route.list` 接受 `{project,limit?:1..100,cursor?:opaque}`，返回 `{items,nextCursor,limit}`。cursor 绑定项目与上一项身份，跨项目、篡改或过期均拒绝；列表索引达到实现上限时拒绝，绝不静默把完整列表伪装成一页。

`knowledge_query` 只建议后续显式 `ask.create`；`workflow_draft` 只建议 `workflows.plan`；`reviewed_execution` 只建议显式 `workflows.run`。每个决定都有 `neverAutoExecutes:true`。路由本身不创建 approval、run、plan 或模型调用。private、其他项目、不匹配 scope、私有来源路径、未知参数和 credential-like question 全部拒绝。

## Reviewed classification proposal

新 route 的 `routeHashVersion` 为 2，hash 同时冻结公开 source candidates 与 workflowCandidates。旧版、无 hash version 的 route 可继续安全读取，但不能创建 proposal；必须重新路由取得 V2 hash。`ask.route.propose` 接受 `project`、route `id`、当前 V2 `routeHash`、一个明确的 Codex JSONL `executable`、`model`，以及受限 `effort`/`timeoutSeconds`。它先立即重验 route/source/workflow 冻结资格；任一候选私有、丢失、改变、跨 scope 或 workflow version/state 变化即拒绝，且不写 proposal/run/approval、更不返回旧 request。只有成功预检才创建 `ask_route_proposal`、pending run 和 `ask.route.proposal.execute` approval；proposal API 返回用户可审阅的冻结输入，包含问题、scope、候选 ID/hash、受限 agent 规格与输出 schema。通用 approval/run 账本只保存 proposal ID 与 request hash，避免成为冻结来源的旁路读取接口。它不启动 provider。

批准后，Core 只通过 `RestrictedCodexProposal` 的 read-only、无 hooks/plugins/apps/shell/MCP/browser/code-mode 的命令运行一次。模型的精确 JSON 只能给出 `kind`、`targetId`、`reason`：

- `knowledge_query` 只可选择 `memory:<id>` 或 `library:<id>`；
- `workflow_draft` 的 `targetId` 必须为空；
- `reviewed_execution` 只可选择冻结的 workflow；
- `reviewed_agent_path` 只可选择仍具 `agent.loop` 步骤的冻结 workflow。

Core 在 provider 启动前重验 route hash、项目、scope、公开状态、source hash、workflow 标题/version/enabled 状态。重验或协议失败会记录失败 proposal，且不会启动 provider（重验失败）或自动发起 query、plan、workflow、agent loop 或外部写入。`ask.route.proposal.get` 仅向同项目返回持久化 proposal；候选在此后变私有或失效时只返回不含 request/result 的安全摘要。未指定项目的通用 Inbox 不显示 Ask proposal；带登记 project 的 Inbox 仅返回同项目、可决定所需的 ID/hash 摘要。成功状态 `proposed` 是建议，需另一次显式产品操作才能执行。

proposal 生命周期沿用现有一次性 approval 的 approve/reject 账本；没有独立的 Ask cancel API 或 `cancelled` proposal 状态。该限制是当前 proposal-only 边界，不表示完整会话式 Ask 产品流程。
