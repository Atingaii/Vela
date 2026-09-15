# ADR 0015：可恢复的工作流组合与产物路由

- 状态：Accepted；实现与验证结果另行记录
- 日期：2026-09-13
- 范围：子工作流输入、pipeline、父子运行、输出交付

Vela 复用现有 Swift 运行器组合工作流，不另建 Agent 框架。参考 [px0 工作流文件](https://docs.px0.ai/workflows/anatomy)：pipeline 按顺序传递文本，条件仅 `always`、`has_output`、`no_output`；跳过透传、失败终止、pipeline 不嵌套。Context 子工作流产生自己的 run，只把产物送回父输入，不重复交付文件或 Inbox。

定义使用显式版本合同并在运行前冻结依赖定义与 hash。依赖必须在同一注册项目，拒绝循环、深度超过 8 或完整依赖展开超过 64 个子节点；pipeline 最多 16 段且首段不得有条件。旧 raw argv 保持字面值；数据只经过既有的一次性模板替换。每个实际 Agent/写入动作仍创建自己的冻结审批，批准父结构不授予所有子动作权限。

运行图与 context 准备游标持久化；父等待状态为 `waiting_child`。子审批完成后推进父链，读取 run 不产生动作。显式 `runs.resume` 只恢复已保存的图与尚未执行的结构阶段，利用原审批 ledger 重建已知结果；`executing` 或 `needs_review` 的副作用不重新执行。跨进程组合 lease 和确定性 child run ID 防止重复派生。

输出是有 hash 的明确文本，支持 stdout、store/output 内文件、Inbox。子运行强制 memory 路由，只有根运行交付一次；文件使用现有 SafeApply 的路径身份、hash 和恢复 journal。计划/调度输出不允许仅 stdout。Dry Run 沿整个依赖图 stub 潜在写入和 Agent；未知模型输出不被当成空文本，依赖它的条件明确阻塞。

这是一种确定性组合，不是模型自主 tool loop。连接器目录、模型选工具和多轮工具调用仍由单独合同实现，不能因为固定 stage 跑通就宣布这些能力完成。

## English

Vela composes existing workflows with frozen definitions, scoped dependencies and individual tool approvals. Ordered stages have three factual output conditions; nested pipelines, cycles and oversized graphs are rejected. Durable parent/child state permits explicit recovery without retrying uncertain effects. Child outputs remain in memory, while only the root delivers a verified artifact. Dry runs preserve unknown outputs instead of treating unexecuted models as empty results. This is deterministic workflow composition, not an autonomous agent loop.

## 恢复边界补充

审批与当前待审批步骤使用同一个 SQLite 事务和源快照 CAS 创建；批准和拒绝都绑定该 run、step 和 approval。命令实际因信号终止或超时后，已有副作用无法由退出码确定，记录 `needs_review`，包括 optional 子输入也不能继续。普通高位退出码与操作系统终止信号分开记录。

文件产物首次写入前，在 SafeApply 的跨进程事务锁内持久化 `run_output.baseHash`。恢复只接受原始 base，或确认目标已经等于本轮 `contentHash`；目标被之后的运行替换时保留较新的文件并要求检查。已有 prepared receipt 不重新获得当前文件的写入权限。旧版没有 baseHash 的 prepared receipt 只能确认内容已相同，不能重新覆盖目标。审批 ledger 已保存 `needs_review` 而 child run 尚未更新的崩溃边界，也必须恢复为 child 与 parent 的 `needs_review`。

English: Pending approvals and run bindings are created atomically with snapshot checks. Timeout and real termination signals require review and never implicitly retry. Managed output persists its original base hash under the write lock before replacement; recovery cannot overwrite a newer run's artifact by adopting its current hash. Persisted uncertain approval results propagate to both child and parent on explicit recovery.
