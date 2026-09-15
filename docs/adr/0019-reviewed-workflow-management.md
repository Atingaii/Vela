# ADR 0019：可检查的工作流管理与有界资产读取

- 状态：Accepted
- 日期：2026-09-13
- 范围：工作流检查/验证、克隆、启停、归档恢复、Markdown 读取边界

参考 [px0 工作流命令](https://docs.px0.ai/reference/cli)和[工作流文件](https://docs.px0.ai/workflows/anatomy)，管理能力应能检查实际定义、隔离坏文件、保留版本，并明确影响未来运行。Vela 继续使用 Swift、SQLite 和 Markdown，不新增文件同步服务或自定义 Agent 框架。

`workflows.get` 与分页 `workflows.validate` 读取实际 Markdown 并走同一纯校验路径，不保存手改、不收集输入、不创建 run。Store 提供项目内的 narrow identity 查询和原始工作流记录读取，避免一份异常资产中断全部验证。每条结果包含确定诊断、资产 hash 和完整 review snapshot hash。

克隆是停用的新身份，保留原 workflow/version/review hash；启停与删除要求匹配最新检查快照。删除采用可恢复归档，默认列表隐藏，但定义与历史证据保留。存在活跃/不确定运行或其他有效定义的引用时禁止归档。恢复默认停用；归档期间的手改不能被静默丢弃。已冻结的运行仍使用自己的快照，启停不声称撤销已经批准的动作。

工作流定义和对应版本在同一 SQLite 事务中保存，并校验原版本与新版本身份。人工编辑的 Markdown 正文保留为原文；显式 context template 才进入模型 argv，不能把普通说明文字或数据重新解释成执行指令。本轮保持原有 JSON frontmatter（YAML 子集）兼容，不声称支持任意 YAML 或递归发现外部目录。

统一 `FoundationFile` 使用 openat/O_NOFOLLOW/O_NONBLOCK、目录及文件身份检查和最多 2 MiB 流式读取，拒绝符号链接、硬链接、FIFO、超限和非 UTF-8。Store 资产、工作流加载与 SafeApply 的读取共用该边界，避免 metadata 检查后再次无界读取，也不在 reader 内构造 Store/SafeApply 服务。

## English

Workflow review and paginated validation are read-only and isolate malformed assets. Clones are disabled with provenance; reviewed state changes retain versions, and removal is reversible archival with dependency and active-run checks. Markdown bodies remain human-owned text unless explicitly selected as a context template. A shared bounded descriptor reader rejects unsafe file types and changed identities without creating services or files. Arbitrary YAML, external recursive discovery and autonomous model tools remain separate requirements.
