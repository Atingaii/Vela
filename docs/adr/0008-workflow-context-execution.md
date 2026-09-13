# ADR 0008：显式工作流上下文与审批前冻结

- 状态：Accepted（采用本合同；不表示 px0 功能覆盖已经完成）
- 日期：2026-09-13
- 范围：Workflow 定义、输入解析、Agent 参数、Run 证据与回放

## 背景

已有 Workflow 执行固定 Git、文件和 command 步骤；Guideline 只被写入 run 快照，没有进入 Agent 参数，Memory 与 Library 也没有接入工作流正文。因此“已有工程资产”不能证明运行实际使用过它。已有 `agent.run` 允许用户自选 executable/argv，自动给旧参数追加 prompt 会改变已授权语义，甚至被某些 CLI 当成路径或新选项。

新目标是让明确声明的工作流使用真实输入与原文工程资产，同时维持旧 command 行为、Private 检索边界和冻结审批合同。应用继续使用 Swift/Foundation/SQLite，不新增模型框架、网络服务或常驻翻译/检索进程。

## 决策

Workflow 可显式声明 `context` v1：`template`、最多 16 个 `inputs` 和 `memory` 策略。首版输入源是固定只读 Git 工具、当前项目公开 Library 检索、显式 stdin、JSON 值。一个输入只能有一个来源，ID 不重复，不允许写工具成为输入。后续输入可引用已解析值；只有完整占位符保留 JSON 类型，字符串内部占位符序列化为文本。仅解析原模板一次，源内容中的 `{{...}}` 保持字面值。未知 placeholder 失败，不访问任意配置或环境变量。

Guideline 以明确 ID 取原文，必须存在、非私有、有效且属于本项目或真实 global scope；禁止用相似度猜规则。Active Memory 复用现有 scope/lifecycle/保守 token 预算合同：默认 2,000，上限 4,000。首版不推断未给出的 branch/task/session 身份，也不声称有 pinned Memory 或语义检索。Memory/Guideline 未在模板指定位置引用时前置注入。超大的最终 prompt 失败，不截断用户规则。prompt 上限 48,000 UTF-8 字节；单定义/模板/输入数量另有上限。

只有 `agent.run` 的 `arguments.promptMode = "workflow_context"` 且 `args` 中有且只有一个完整 `{{vela.prompt}}` 元素时才注入。整个 prompt 替换为一个 argv 值，不经过 shell 字符串拼接，不改变 executable 或其它参数。没有显式模式的旧 raw argv（包括恰好相同的字面占位符）保持不变。Vela 不猜 provider CLI flags；用户选择的完整命令仍是合同。支持通用已审批进程不等于已经验证所有模型 provider。

每次运行在任何 Agent 命令审批前，解析并持久化 prompt、输入、来源、Guideline 版本、Memory 内容 hash/更新时间及上下文 hash，随后把同一文本放入待审参数。审批仍绑定原有 frozen payload、一次性 CAS 和项目；之后修改 Workflow、Memory 或 Guideline 不会更改待审动作。内容由 Vela 显式提供给获批进程；该进程自身权限不是 Vela 检索沙箱。Dry Run 解析受限只读输入并展示快照，所有 Agent、测试脚本和写入继续 stub。

读取旧 run 的 replay 改为复用已捕获的只读结果和上下文，所有命令/写入/模型均不执行，标签为 `captured_records_no_execution`。没有捕获的历史读取标 unavailable，不用今天的 Git 状态补造过去。此模式是审计回放；两版本实际模型输出、diff、fixture 独立保留/到期仍是后续能力，不能称完整 px0 replay。

## 取舍与边界

比自动给所有 command 注入更明确，比引入通用 agent loop 更小，也保持现有未接入 context 的工程操作兼容。代价是用户需为每个 harness 指定已知 prompt 位置；stdin 写入、子workflow、pipeline、外部连接器、模型tool循环、混合检索及独立fixture保留策略尚未覆盖。本切片不移除这些全集验收要求。

context v1 是显式选择保存运行内容：其输入和最终prompt会保留在本地run与审批账本，可能含敏感工作文本。此处不增加分享/导出这些对象的入口。未来全store导出/同步必须默认排除这些运行快照，不能仅检查凭据文件。构建工具应先呈现数据范围，再产生可审阅的具体执行请求。

整体进程时限、输出截断、环境净化、后代清理和项目文件写入安全沿用既有实现。把 template 内容传给模型不证明模型遵守了指令，也不证明产物改善；需要独立验证和真实 provider 证据。

## 验证

[WorkflowContextTests.swift](../../Tests/VelaCoreTests/WorkflowContextTests.swift)使用独立临时项目、真实接收脚本和 Core：核对实际收到的 prompt 字节，审批后资产变更、一次性执行、原始 argv、Dry Run、Private/项目隔离、typed 值、预算与缺输入失败、历史状态回放、Markdown 手改。没有调用付费 Agent、外部 SaaS 或用户真实配置。

本地第一次全量回归暴露了 optional context 比较的顶层 JSON 标量序列化问题，修复后 context 八项与已有 AutomationTests 通过；完整仓库最终测试由集成验证记录维护。最终公开成功状态应链接具体 commit/CI，不以本 ADR 的 Accepted 代替验收。

## English

**Accepted.** An optional, versioned workflow context explicitly resolves bounded read inputs, named guideline text and eligible active memory into one frozen prompt. Only an `agent.run` step opting into `promptMode: workflow_context` replaces exactly one whole `{{vela.prompt}}` argv entry. Legacy argv remains literal, and no provider flags are guessed. Template values are not recursively interpreted.

Run and approval records retain the exact resolved text, source hashes, available guideline versions and memory timestamps before execution. Editing an asset later cannot change an approved payload. Dry runs still stub agents, project scripts and writes. Context records stay local; future export/sync work must treat them as sensitive execution snapshots.

Replay reuses historical captured records without tools or models; missing captures remain unavailable. This is not dual-model evaluation. External connectors, planner/tool loops, sub-workflows, pipelines, pinned or semantic memory, and fixture retention remain explicit parity requirements. The tests use isolated projects and an actual fixture process, establishing delivery of bytes rather than provider behavior or improved outcomes.
