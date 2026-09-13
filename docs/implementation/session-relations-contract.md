# Session relations / 会话关系只读合同

本切片以 Codex `rust-v0.154.0` 的固定 [公开协议](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/protocol/src/protocol.rs) 为依据。它提供当前已摄取来源的父子访问路径，不代表 Blume 全部子代理功能已完成，也不代表 Cursor、Claude、Pi、OMP 已有同等关系解析。设计见 [ADR 0030](../adr/0030-observed-codex-session-relations.md)。

## Identity and eligibility / 身份与可见性

所有查询均只读，不刷新来源、回填历史或运行 provider。除 `describe` 外必须传绝对、已注册的 `project`。`id` 是 Vela 的文件来源身份；`threadId` 是提供方规范 UUID，两者不可互换。大小写 UUID 归一化；同项目多个可见文件使用同一 thread UUID 时为 `ambiguous`，不任选一份。缺失、跨项目、private、私有来源、internal 或不合格 scope 均不解析为可访问节点。

显式 `source.internal` 的 `guardian`、`memory_consolidation` 及未来未知 internal 子值都不可见。旧 `source.subagent:"memory_consolidation"` 是不同的公开序列化形状，不能只凭名称伪称它是新 internal 枚举。来源后续出现 internal header 也立即排除关系访问。未知、冲突或尚未投影的 header 不能获得 `resolved` 身份。

来源摘要仅包含 `id/project/provider/sourceThreadId/title/observedState/statusSource/liveness/lastActivity/historyTruncated`；title 至多 300 个字符并脱敏。它可能来自已有会话标题，不是会话正文访问 API。关系查询不返回 messages、原始工具参数或模型提示词。父子状态各自来自已持久化日志；`liveness:"unknown"` 不证明进程仍运行。

## Five methods / 五个入口

所有参数对象拒绝未知字段；整数拒绝布尔、字符串、负数和小数。

| Method | Parameters | Result |
|---|---|---|
| `sessions.relations.describe` | `{}` | decoderVersion、provider/referenceVersion/referenceCommit、只读与限制说明 |
| `sessions.relations.get` | `{project,id}` | source、relation、parent、headerEvidence、parentClaims |
| `sessions.relations.resolve` | `{project,threadId}` | status；仅唯一、有效、可见来源有 source/relation |
| `sessions.relations.children` | `{project,id,limit?:1…100,after?:opaqueCursor}` | items、nextCursor、scanned、omitted、pageComplete、relationEpoch、parentState、childErrorsOnPage |
| `sessions.relations.events` | `{project,id,limit?:1…100,afterSequence?:0…9007199254740991,epoch?:string}` | items、nextAfterSequence、hasMore、relationEpoch、oldestRetainedSequence、eventsTruncated、coverageLimited |

`children` 默认 20 条，按来源 ID 排序；游标绑定项目、anchor ID、provider UUID 与 relationEpoch。按最后扫描 ID 前进，被隐私筛掉的空页仍可能有 nextCursor。它只列 metadata 明确声明该父 ID 的当前索引来源；候选冲突项标明冲突/身份歧义。`explicit_parent_metadata` 描述直接声明事实，不承诺整个祖先图无环；`get.parent` 另检查最多 32 层祖先并报告 cycle、缺失祖先或 depth_limit。对其他节点的更新不提供冻结事务式分页快照。

`events` 默认 50 条，只保留最近 128 个事件；afterSequence 大于 0 时必须带同 epoch。最多保留 32 个未决调用和 256 个已结算调用去重记录，超界明确 coverageLimited。`proposed` 是工具请求；`reported_spawned` 只表示配对回执报告 agent_id，子来源尚未存在时 childResolution 为 unavailable。子来源与 parent header 独立匹配后才是 corroborated。冲突 call ID、变化的回执 namespace/type、失败/未知格式不会得到唯一子对象。后续源 header 冲突时旧回执仍可保留作观察证据，但禁止继续显示 corroborated。

## Evidence and continuity / 证据与连续性

关系拥有 decoderVersion 和独立 relationEpoch，与 session/plan/ingestion 同一 CAS batch 保存。`headerEvidence` 与调用/回执 reference 含 sourceIdentity、sourcePath、sourceVersion、byteOffset、byteLength 和原记录 SHA-256；byteLength 不含行末 LF，调用回执附 proposalReference。字节证据可在合成原文或显式 History 路径中回查；查询本身不读全文。sourceVersion 是文件身份/修改版本，不冒充完整文件内容摘要。

迁移、文件轮转、缩短、同长重写或原 header 字节改写后建立新 epoch。大文件的 32 KiB 前缀只接受完整换行记录，不能把恰好可解析的截断 JSON 当成完整 header。文件变长时额外核对已记录 header 的精确字节摘要，因此同 inode 的 header 改写不会借旧 offset 留住旧父节点。**其余过去记录仍依赖 provider 的 append-only 行为**；这不是任意文件重写检测，也不保证所有历史 spawn 事件完整。默认文件数、256 KiB 尾窗及 History 显式回填保持原边界，不通过简单扩大 cap 冒称全历史。

当前确认的成功路径是 `function_call`（name 为 spawn_agent，namespace 缺省或 multi_agent_v1）和同 call_id 的 `function_call_output` 文本 JSON `{agent_id,nickname?}`。普通 forked_from_id、根 session_id、目录相邻、自然语言提及、未成功的工具请求均不推断父子。本轮 Codex 关系抽屉已通过合成数据浏览器验收，覆盖分页、隐私、竞态与支持尺寸下的抽屉头部几何；未核验的 v2/code-mode 输出、其他 provider、完整历史图、持续运行进程与 native 交互仍独立验收。

## English summary

The five project-scoped methods expose bounded Codex metadata and paired spawn observations without executing a provider. Vela source IDs and native thread UUIDs remain distinct; fork provenance, parent links and each session's own lifecycle state stay separate. Private/internal/conflicting sources do not resolve. Epoch-bound pagination, exact record references and header continuity protect observed lineage, while older non-header bytes still rely on the provider's append-only contract. The API does not claim a complete historical graph or process liveness.
