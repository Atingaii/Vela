# ADR 0021：由冻结来源支持的受审知识问答

- 状态：Accepted；实现、真实 provider 和 UI 验证分别记录
- 日期：2026-09-13
- 范围：Brain Ask、逐条引用核验、连续问答与专用运行

参考产品提供基于本地知识的模型问答。普通搜索结果拼接不能替代回答生成；把检索结果直接塞入任意 agent 命令又无法区分来源、权限和执行结果。因此 Vela 增加独立的 `knowledge_query` 记录，由 `KnowledgeQueryService.swift` 承担来源选择、冻结、模型结果核验与安全读回。

当前仅纳入已登记项目下明确公开的 Active Library 和 scope 匹配的 Active Memory。没有跨项目或隐式全局 Memory；branch/worktree/task/session 需要明确相等的上下文。Private 标记类型错误不当作 false，Library 缺少显式公开标记也不进入模型。搜索只提供候选，随后按 kind/id 重新 `store.get`，读取当前 managed Markdown，检查实际资产存在、来源路径、隐私、状态、scope 与内容。原导入文件不自动重新抓取，事实来源是当前 Library 导入资产。

每轮保存 question、scope、有限来源片段及完整源 hash、脱敏片段 hash、历史、输出 schema、选定 Codex executable/model/effort、预算和精确命令 hash。首次创建原子发布 question/run/approval，同时 CAS 检查来源对象。无命中创建 `no_sources` 和专用 completed run，不产生审批，不调用模型，不伪造空答案为成功推理。

审批仍使用现有一次性领取机制，但通用 approval/run 的参数仅包含 ask ID、request hash、command hash。完整来源仅保存在 question 中，`ask.get` 每次重新核验来源后才展示。这样来源后来被设为私密时，通用 Inbox/Run 不会旁路暴露旧来源正文，专用 API 也会隐藏旧答案和请求。已经公开时产生的本地冻结记录仍用于审计；此机制不是追溯删除外部 provider 已处理的数据。

每轮审批最多一个 Codex 请求，复用 `RestrictedCodexProposal` 的固定禁工具 flags、独立临时 cwd、有界协议与完整单答检查。不是模型工具循环，没有后台模型调用、自动续问、自动激活 Memory、写文件或自动 Apply。外部命令限制依赖所选官方 CLI 的协议与沙箱；临时目录本身不是 OS 沙箱。

结构化回答由 `claims[{text,citations:[{sourceId,quote}]}]` 和 `unanswered` 组成。Core 校验每条 claim 至少一处、至多四处引用；source ID 必须属于冻结集合，quote 必须是对应脱敏片段中非空的连续原文，不能引用脱敏占位。未知字段、错误引用、缺失引用、工具事件、半截协议、超限或源变化全部拒绝。模型原始协议不保存正文，只保留 hash、完成指标和安全失败原因；未通过核验的输出不能进入 run/inbox。

调用前、发布答案前和读取答案时均核验来源。最终发布再次通过 Store CAS 检查当前源对象。引用存在只证明原文可回查，不证明 claim 与引文语义一致、原材料可信或真实任务改善；记录固定 `semanticCorrectness:not_verified`，冲突与无法回答应显式展示。

Follow-up 是新的 question/run/approval，每轮重新选定模型和预算，保留之前问答但不把模型答案当来源。最多八轮，保留之前的全部冻结来源并重新核验，不允许缩减预算静默丢掉旧引用；任一旧来源改变、私密或不可读就拒绝续问，用户需从当前材料发起新问题。历史使用当前 askHash 绑定。

继续采用 Swift/Foundation/SQLite，不新建常驻检索服务或 agent 框架。默认候选查询是有界的已索引 substring，且旧索引可能漏掉未刷新的人工作品。显式 library_fts 模式复用 Library FTS5/BM25 候选，将命中段落、anchor 和 UTF-16 范围与当前完整源快照逐项核对后冻结。该模式不自动索引或静默 fallback，Memory 仍使用词面候选；后续 Memory hybrid 是独立接入项。候选排序/片段覆盖不足不能从“一个答案通过引用检查”中被宣布解决。

## 验证与关联

- [API 合同](../implementation/knowledge-query-contract.md)
- [KnowledgeQueryTests](../../Tests/VelaCoreTests/KnowledgeQueryTests.swift)：合成 provider 的真实进程、来源/审批/输出/续问与泄漏回归。
- [ADR 0012](0012-reviewed-workflow-planning.md)、[ADR 0014](0014-model-improvement-proposals.md)：共享受限模型传输，但独立请求、schema 和授权预算。
- 公开能力依据见 [px0 全量清单](../parity/px0.md) PX0-078、085、086；官方页面本次 web fetch 失败，未据失败推断产品功能不存在。

## English summary

Knowledge Ask is a reviewed, one-call answer over frozen public project sources. Source selection, exact citations, private/active/scope checks and revalidation are owned by Core. Each follow-up gets a separate approval and run; no automatic tools, memory activation or background calls are introduced. Generic runs and approvals retain hashes rather than source text. Exact quote matching is provenance verification, not proof of semantic correctness. Bounded lexical candidate retrieval remains distinct from the subsequent Library search work.
