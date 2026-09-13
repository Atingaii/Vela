# Workflow Planning 合同 v1

本合同只定义已接通的 Codex CLI 规划入口。它没有连接外部工具目录，不自动创建可运行工作流，不替代完整 px0 功能验收。模型负责提出结构化计划；Core 校验并构造停用 draft。UI 实现仍必须由 Antigravity CLI `gemini-3.8-flash-high`、effort `high` 完成。

## 创建待审规划

`workflows.plan` 参数：

```json
{
  "project": "/absolute/registered/project",
  "description": "总结当前工作区的变更，列出需要进一步检查的问题",
  "executable": "/absolute/path/to/codex",
  "model": "user-selected-model",
  "effort": "high",
  "answers": [],
  "timeoutSeconds": 120
}
```

- `project` 必须已登记且存在。`executable` 和 `model` 必须显式指定，不自动挑模型或登录。
- `effort` 支持 `low/medium/high/xhigh`，默认 `high`；未知值拒绝。时限为 1–300 秒，默认 120。
- description 为最多 8,000 UTF-8 字节；每轮至多 8 条非空 answers，每条最多 2,000 字节，完整规划 prompt 上限 48,000 字节。NUL 拒绝。
- 调用只原子创建 `workflow_plan`、`run` 和 `approval`。状态为 `pending_approval`；尚未启动进程、读取项目内容或生成工作流资产。
- `request` 冻结原始请求、当前描述、每轮回答链、工具目录/schema、model/effort及协议版本。审批 `arguments` 同时冻结 `requestHash` 和完整 `commandTemplate`。唯一运行时替换是由 Core 创建的私有临时 schema 路径。

可用目录仅 `git.status`、`git.diff`、`git.log`。schema 不接受任意 executable、command、tool slug或shell文本。Read 工具由 Vela 在未来明确接受的工作流运行中调用；规划进程没有业务工具调用需求。

## 展示与批准

创建响应和 `workflows.plan.get({project,id})` 返回：

```json
{
  "id": "plan-id",
  "project": "/registered/project",
  "state": "pending_approval",
  "request": {},
  "requestHash": "sha256",
  "planHash": "sha256",
  "runId": "run-id",
  "approvalId": "approval-id",
  "approval": {"snapshotHash": "sha256", "arguments": {}},
  "questions": [],
  "unresolved": [],
  "savedWorkflow": false
}
```

UI 应呈现描述/回答、选定 CLI/model/effort、可能的模型调用费用、无外部连接器、确切输入范围与同一待审 payload；不得把“生成计划”误描述为完全离线。请求和返回正文保持原文，固定 UI 标签中英切换。

实际批准仍使用已有入口：

```json
{"id":"approval-id","snapshotHash":"reviewed-hash","decision":"approve"}
```

方法为 `approvals.decide`；拒绝使用 `decision:"reject"`。原子 CAS 只能领取一次。Core 检查 plan/request/schema/registry/命令仍与冻结内容一致；代码合同变化时失败并要求重新规划，绝不自动去掉不支持的 flags 后重试。

批准后运行选定 Codex CLI，工作目录为新建、权限 0700 的独立临时目录，写入 0600 output schema。使用 `exec`、`--ignore-user-config`、`--ignore-rules`、`--ephemeral`、`--skip-git-repo-check`、`--sandbox read-only`、结构化输出并禁用 hooks/plugins/apps/shell/browser/computer/multi-agent 等相关能力，清空 MCP server 配置。读取/写入用户项目文件不是规划输入。进程完成或失败后删除本次临时目录。

这些是针对已检查 CLI 版本的执行约束；真实 provider 的测试另行记录。它们不构成对任意用户提供可执行文件的 OS 安全保证。模型产物必须解析成一次完整 JSON 答案；非零退出、超时、截断、partial protocol、工具事件、未授权字段或未知引用均失败。

## 结果、追问与明确接受

状态：

| state | UI 应表达的含义 |
| --- | --- |
| `pending_approval` | 规划请求待批准，模型未调用 |
| `executing_or_uncertain` | 已被领取；不能仅靠账本断言进程仍活着，禁止重试 |
| `draft` | 可审阅 draft，仅存在 plan 内；尚无 workflow 资产 |
| `needs_clarification` | 有 `questions` 或 `unresolved`；不能当成完成计划 |
| `rejected` | 用户取消，模型未因该请求执行 |
| `failed` | 执行或校验失败，保留错误/协议证据，不自动重试 |

`draft` 包含可提交给 `workflows.save` 的数据：`enabled:false`、`trigger:manual`、空 guidelines、显式 context inputs/template，及使用同一已选 CLI 的受限 `agent.run` 步骤。模型不能指定 executable 或写工具。生成报告步骤仍需要后续独立审批。Memory 默认关闭；不得未经审阅扩大上下文范围。

UI 的“接受为工作流”必须显式调用 `workflows.save(draft)`；规划接口永远不调用它。不要在成功 toast、轮询或读取详情时顺手保存。`needs_clarification` 不给可执行 draft。

追问是一个新的待审请求：在 `workflows.plan` 参数中加 `previousPlanId` 和从上次详情读取的 `previousPlanHash`，附上当前 answers 和 description。Core 保留 `originalRequest`、累计 `answerHistory`、上轮 questions/summary，最多 8 轮。旧 plan 改变、仍待批或执行不确定时拒绝。新请求仍需自己的审批，不继承上一轮执行授权。

`workflows.plan.cancel({project,id,planHash})` 只取消仍 pending 的计划，内部复用 reject/CAS。对正在执行或不确定的请求不会发送 kill，也不会假装已经取消。当前没有规划进程的主动中断 API。

## 列表、持久化与证据

`workflows.plan.list({project})` 返回最多 100 个轻量摘要：identity、state、planHash、run/approval IDs、时间与 questions/unresolved。原始协议、完整请求、审批参数及draft只在 `.get` 返回，避免列表反复发送长 prompt。

计划与运行存在本地 SQLite；成功和失败的有界原始协议为本地证据。token 只接受完整 provider usage，缺失保持未知。fakeCLI fixture中的用量只是合成协议数据，不是实际服务账单。

应用重开时，根据审批账本派生执行/拒绝/失败视图；已开始或结果不确定的规划不会自动再执行。新 store export/sync 不得默认包含这些敏感 request/rawProtocol/approval 内容。

## English summary

`workflows.plan` creates a frozen planner request, a run and a one-shot approval. No model runs before approval. The selected Codex CLI runs with explicit restrictions in a disposable isolated working directory. Its single structured result is untrusted data, checked against the frozen read-only registry and schema. The only successful artifact is an unsaved, disabled draft; accepting it requires a separate explicit `workflows.save` call, and running it requires its own approval.

Follow-ups bind the previous plan hash and preserve the original request and answer history. Cancellation only rejects pending approval; executing or uncertain requests are never silently retried. Full details and sensitive protocol evidence stay local; list responses are summaries. These contracts are not proof of complete reference parity or real provider success.
