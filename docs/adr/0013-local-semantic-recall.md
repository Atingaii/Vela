# ADR 0013: Local semantic recall / 本地语义召回

- Status: Accepted
- Date: 2026-09-13
- Scope: Optional embedding provider, SQLite vector persistence, public recall/index API

## Context / 背景

用户要求完整对照 Walrus Memory 的语义检索、recency/importance 排名与应用接入能力。旧词面召回无法覆盖同义表达。引入语义模型不能增加 Mac 安装包的 Node/Python 服务、云端默认请求或虚构的 hash embedding，也不能削弱 Private Library 和项目隔离。

## Decision / 决策

使用系统 `NaturalLanguage.NLEmbedding.sentenceEmbedding(for:)` 提供的可选本机 English / Simplified Chinese 模型。仅按需加载 `en` 或 `zh-Hans`，没有主动下载和第三方调用。本机模型缺失返回 `unavailable`；hybrid 可显式降级至词面召回。模型来自 Apple 的安装状态，不能假设所有 macOS 安装均有相同资产、版本或维度。依据 [Apple NLEmbedding](https://developer.apple.com/documentation/naturallanguage/nlembedding)。

提供 `SemanticEmbeddingProvider` 内部边界，生产实现使用真实 sentence vectors，测试注入小维向量只核验数学与权限。Memory 的 title/content 按 512 Unicode scalars 分块，逐块归一后平均并再次归一。Vela 算法 ID 为 `apple.naturallanguage.sentence.mean512.v1`，同时固定实际 language/revision/dimension；这不是宣称 Apple 提供了同名文档模型。分块平均减少长文截断依赖，但会弱化段落位置语义，仍需领域检索样本评估，不能由少数同义测试推导普遍质量领先。

SQLite 增加 `memory_embeddings` 表，主键 `(memory_id,language)`，向量以 Float32 little-endian BLOB 保存。只增加内部窄分页、写入、metadata、删除和流式遍历 API，不公开任意 SQL。每向量检查维度 1–4096、全有限值、非零模、BLOB 字节数；余弦计算再次校验。每次只读一个 vector，最多保留 top-K 结果，模型只在实际使用时创建。

来源摘要绑定 title/content/project/scope 与 branch/worktree/task/session 约束。写入向量前在 `BEGIN IMMEDIATE` 中重新核对当前来源和摘要，拒绝生成期间被修改或变私有的来源。Recall 必须再次校验当前来源、模型和摘要，旧向量不能被召回。删除 Memory 删除索引；变 private 清除所有语言向量。项目须登记，global 仅接受无项目归属的允许共享记录，Private Library、私有来源路径、非 active 与范围不符记录均排除。源 Markdown 人工改动也参与摘要，不能只看 SQLite 旧正文。

`memory.semantic.index {project,language,batchSize,cursor}` 显式分批索引，batch 1–200、页读取约 2 MiB。游标绑定 project/language/model/revision；可以退出并从下一页恢复。每条完成独立持久化，失败页可能已有成功条目，响应给 processed/indexed/unchanged/skipped/failed。没有隐式启动扫描、每次 Recall 自动重建或下载。导入候选必须审核激活后才会进入索引。

`memory.semantic.status` 核对当前来源与 metadata，报告 eligible/indexed/stale/missing 与 incomplete。它是逐条读检查，不是锁住所有文件/跨进程的全局快照。新记录 ID 排在既有游标之前或并发编辑时，应完成当前遍历后核对 status，再按需新遍历。完整 status 和 recall 的覆盖度核对与库大小线性相关；此版本有内存边界，没有总扫描时长保证，不伪造大规模性能指标。可复用后续后台增量更新，但不能以过期完整标志替代当前校验。

原 `recall` 默认 lexical 保持兼容。semantic/hybrid 接受 threshold（0–1）、limit（1–100）、token budget（0–4000），默认只按余弦相似度；用户可指定 semantic/recency/importance 权重和半衰期。日期或显式 importance 缺失时相应加权项为中性，不把缺失统计标记为真实测得零。hybrid 保留词面来源标记，重复结果合并；词面独有结果分值上限 0.5。先保留 top-K 后进行 token packing，因此大条目可能导致预算未完全使用；`limited` 和 `truncated` 明示截断。所有评分是检索排名，不是置信度、推理质量或改善百分比。

MCP 只扩展既有 `vela_recall` 只读参数，不自动获得索引写权限。SDK 增加 typed index/status/recall 方法，固定沿用禁 watcher/scheduler 的本地进程合同。索引是可重复扫描的写操作，但传输超时仍保守报告未知副作用，不自动重试；当前状态可用于后续明确恢复。接口详情见 [integration contract](../implementation/semantic-memory-contract.md)。

## Alternatives / 取舍

- 外部 embedding HTTP API 需要凭据、成本与网络边界；不作为本机默认路径。以后可作为用户明确选择的独立 provider。
- 嵌入第三方大模型/向量数据库会增加包体、运行时和运维；当前规模先使用系统模型和 SQLite 流式精确扫描。
- FTS/词面检索仍是可靠且无需模型的默认入口，但无法单独覆盖真实语义检索。
- 把词频/hash 向量命名为 embedding 会误导能力对照，因此不采用。

## Verification / 验证

算法固定向量测试与真实 Apple 模型测试分别标记。覆盖分页恢复/重启、模型版本/语言/项目游标隔离、跨项目/私有/生命周期、源内容改动失效、错维/NaN/零向量、显式排序/阈值/预算、缺模型返回与 hybrid 降级。实际安装包 SDK 使用 synthetic 项目，由独立 Core review 激活候选后进行同义召回。测试不代表远端 Walrus 恢复、owner/delegate、云端模型、所有 middleware 或跨机器同步已交付。

## English summary

Vela uses optional installed Apple sentence embeddings without model downloads, extra runtimes, or default network calls. Explicit resumable indexing stores versioned Float32 vectors in SQLite, with source-hash and scope/privacy checks before storage and every recall. Lexical remains the default; semantic/hybrid retrieval reports unavailable assets, incomplete indexes, ranking sources, and truncation. Precise streaming search bounds memory but has linear scanning cost. SDK/MCP access follows existing authority; this local capability does not imply remote encrypted-memory or ownership parity.
