# ADR 0012：经审批的 Codex 工作流规划

- 状态：Accepted（协议采用；真实模型与界面验收另行记录）
- 日期：2026-09-13
- 范围：自然语言规划、有限访谈、模型输出校验、停用草案

## 背景

现有 `workflows.build` 是透明的本地关键词规则，只能从固定工程语句生成几个步骤，不满足“描述目标后获得可执行工作流”的完整能力。项目需要模型参与规划，也必须继续复用已有 coding-agent CLI，保持无额外框架、明确费用与一次性审批。

直接将任意模型 JSON 交给 `workflows.save` 会把模型拼出的 tool/executable 变成能力授予；直接以用户项目为规划 cwd 还会扩大读取范围。将规划混入已有 Lab 会混淆单次草稿与实测改善证据。

## 决策

新增独立 `workflow_plan` 对象与专用内部 `workflow.plan.execute` 动作。公开 `workflows.plan` 只原子保存待审请求、run 和 approval。请求必须有已登记 project、描述、明确 executable/model；冻结用户原始文字、回答历史、协议、工具 registry、严格 output schema、CLI 参数模板。批准复用现有 frozen hash/CAS，一次领取，失败或不确定不会自动重试。

执行只调用用户选择的 Codex CLI。当前已通过该 CLI 本地 help/features 确认的参数用于隔离 user config/rules、禁用多余工具与hooks、read-only sandbox、ephemeral会话和结构化输出。使用新建的 0700 临时 cwd，schema为0600；本次临时目录在完成或失败后移除。规划不拷贝项目、Session、Memory、Library、凭据或用户配置。所选 CLI 仍使用自身登录；Vela不要求或保存模型 API key。

解析使用 Codex JSONL envelope，要求完整结束、唯一结构化答案及无工具事件。输出只能指定 title/summary/template、固定 Git readTool IDs、questions 和 unresolved。模型不能指定命令/路径/权限，不存在的外部连接器不能被当成已接通。Core 才能把合法数据构造为 `enabled:false`、manual、无自动Guideline/Memory扩权的 draft，仍只放在 plan 内。

接受 draft 必须显式调用独立 `workflows.save`，执行已保存工作流仍走后续审批。`needs_clarification` 没有可执行draft。追问产生新的待审请求，绑定之前详情的 hash，保存原请求和累计回答，最多8轮；旧请求尚待批或执行不确定时不能借“继续对话”触发另一轮模型调用。cancel仅拒绝未开始的请求，不冒充主动终止已运行进程。

旧 `workflows.build` 保留为不调用模型的本地 fallback；新功能名和证据明确区分。规划UI由指定Antigravity模型实现；此ADR不实现前端。

## 取舍

选择独立规划作业比把每个自然语言输入自动发送给模型多一个明确审阅节点，但能固定费用相关参数、输入范围和命令。结构化子集不等于完整px0规划；未来连接器发现、更多harness、mutating tools/pipelines必须通过各自schema、授权和验收扩展registry，而不是让模型返回任意代码来绕过当前限制。

当前工具限制与CLI参数依赖已检查版本。旧版CLI不识别限制参数时失败，不删掉限制重试。用户指定的任意可执行文件本身不因此成为可信OS沙箱；真实provider验证需单独核对执行协议、工具使用、网络与实际费用。模型把要求写成流畅文字不证明它可实现或质量提升。

保留有界本地原始协议和usage来源便于诊断；列表只返回轻量摘要。规划数据与审批可能含敏感工作文字，未来export/sync不可默认包含。不得将fakeCLI合成usage称为真实服务用量。

## 验证

[WorkflowPlanningTests.swift](../../Tests/VelaCoreTests/WorkflowPlanningTests.swift)通过真实进程模拟 Codex JSONL，覆盖未审批无执行、真实argv/cwd、停用草稿不自动保存、未知tool/executable/模板namespace拒绝、工具事件/partial/nonzero失败、原请求和回答链、stale previous hash、取消/重开/不确定不重试、原始请求篡改和跨项目访问。完整集成与真实provider结果由验收记录维护；这里的Accepted不意味着这些外部验收已通过。

界面和调用方参阅[Workflow Planning合同](../implementation/workflow-planning-contract.md)。总范围见[px0台账](../parity/px0.md)。

## English

**Accepted.** Natural-language planning is a separate reviewed job using an explicitly selected Codex CLI, not a new agent framework. The request, exact command template, schema and read-only registry are frozen in an atomic plan/run/approval creation. Approval is one-shot; failures and uncertain executions never automatically retry.

The CLI runs with inspected restrictions in a disposable working directory, without copying project data or credentials. Its structured answer cannot grant executable paths or tools. Core validates it and constructs an unsaved, disabled draft. Saving and executing that draft require separate actions. Follow-ups bind the previous plan hash and retain the original request and answers; cancellation only handles pending requests.

The deterministic builder remains available offline. Fixed-registry planning is a first implementation stage, not full reference parity. Fake-CLI tests establish protocol and process behavior; real provider effectiveness, usage and UI acceptance require separate evidence.
