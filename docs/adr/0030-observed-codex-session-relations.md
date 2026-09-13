# ADR 0030：有来源证据的 Codex 父子会话关系

- 状态：Accepted；运行证据单独记录
- 日期：2026-09-13
- 范围：B13 的 Codex rollout 只读关系投影；其他 provider、Cursor 历史和 UI 分别推进

## 依据与选择

固定官方 `rust-v0.154.0` 对应 commit `6b9826e3aa83b1a5947db50f4332cb9c65f1b340` 的 [protocol.rs](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/protocol/src/protocol.rs)。`parent_thread_id` 与 `forked_from_id` 是不同事实；`SessionSource` 使用 lowercase serde，`SubAgentSource` 使用 snake_case。`source.subagent.thread_spawn.parent_thread_id` 明确描述父线程。普通 fork、目录相邻、相同标题和正文中提及其他线程均不能证明子代理关系。

成功回执形状另据同提交的 [spawn handler](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/core/src/tools/handlers/multi_agents/spawn.rs) 与 [ResponseItem/FunctionCallOutput](https://github.com/openai/codex/blob/6b9826e3aa83b1a5947db50f4332cb9c65f1b340/codex-rs/protocol/src/models.rs) 核验：外层 call_id 关联请求，输出文本 JSON 的 agent_id 是新线程 ID；不从正文中的 UUID 或内部未序列化 success 字段猜测。显式 `source.internal`（包括未来未知子值）排除；它与 legacy subagent 名称分开处理。

先完成已有 Codex JSONL 的可回查关系路径，而不同时重写 Cursor 存储读取。Cursor 未公开/未验证的 bubble schema 仍保持未知，不以一份合成导出声称兼容所有客户端版本。

## 数据与迁移

新增 `session_relation` 派生对象，以现有 Vela 来源身份为 ID，与 session、session_plan、ingestion 在同一个 `putBatch` 内提交。不改提供方原文件，不丢弃 History 原文。投影拥有 decoderVersion 和独立 relationEpoch；旧游标缺少新 decoderVersion 时重新观察可用 header/最近窗口。来源轮转、重写和解码器迁移建立新 epoch，旧关系不进入新来源。只读 API 不触发回填或扫描。

投影保留规范的 provider thread UUID、项目归属、providerVersion（缺失为 null）、父声明列表、fork来源、原始记录位置/hash/sourceVersion、有限的调用关联与事件。来源变更或重复 header 身份冲突不能选择性覆盖较早声明来制造确定关系。默认摄取仍有窗口；header未完整观察、调用配对被截断和未知格式明确报告 coverageLimited，不声称完整历史图。

大文件只接受前缀中的完整换行 header，不能把截断前缀恰好可解析的 JSON 当成完整记录。变长文件额外校验旧 header 的精确字节摘要；同 inode 改写 header 会建立新 epoch。其余过去字节仍依赖提供方 append-only 行为，sourceVersion 也不是完整文件 SHA-256。这一有界连续性检查不能冒称任意重写检测或完整历史图。

父 metadata 的两个来源若冲突，保留冲突而不任选一个。只接受明确 `spawn_agent` function call 与同 call_id 的结构化成功输出中的 agent_id 作为提供方“报告创建”证据；工具提议、非结构化错误、缺失回执不成为已创建子实体。子日志的明确 parent 声明是另一个独立证据。原生 thread 身份不与 Vela 文件来源身份混用；重复 thread UUID 对应多个可见来源时返回 ambiguous，不能静默去重选择一个。

## API 与权限

`sessions.relations.describe/get/children/events/resolve` 由 FoundationService 精确分派，仅只读。除 describe 外必须选择已注册绝对 project；get/children/events 使用 Vela session ID，resolve 使用提供方 thread UUID。响应只返回必要 summary 与关系证据，不返回会话正文、提示词或工具参数。所有节点均从当前 session 记录校验同项目、非 private、非 private来源、非 internal、可用 scope；缺失与不可见使用同一 unavailable 结果。

Store 新增静态窄查询，分页先取 source identity/summary，不能为关系图加载所有会话正文。children 的游标绑定项目、anchor身份及 relationEpoch，并按最后扫描的来源 ID 前进；过滤为空不等于读完。events 以同 epoch 的 sequence 分页，保留范围与截断明确报告。列表是当前已观察来源扫描，不是冻结的全历史图。

父子状态分别来自各自持久日志记录；子错误可以作为关系结果显示，但不能覆盖父 session 状态。完成、失败和 Running 仍是日志观察，process liveness 保持 unknown。父来源未摄取、跨项目、私有、身份重复或关系冲突都不能被描述为验证完成的父子关系。

## English summary

Codex parent-child relations are a read-only projection of explicit, version-pinned rollout metadata and paired spawn acknowledgements. Fork provenance remains separate. Relation objects commit with the existing ingestion batch, carry their own epoch and bounded evidence, and expose project-scoped summary/pagination APIs. Missing, private, ambiguous and conflicting sources never become inferred verified links; parent and child lifecycle observations remain independent and do not establish process liveness.
