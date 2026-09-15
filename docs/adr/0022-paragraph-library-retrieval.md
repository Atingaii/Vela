# ADR 0022：可恢复的资料管理与本地段落检索

- 状态：Accepted
- 日期：2026-09-13
- 范围：Library 生命周期、来源更新、SQLite FTS5 段落索引

Library 的现有 create-only 导入与 LIKE 搜索不足以完成资料管理和带引用问答。继续使用系统 SQLite/FTS5，不引入搜索服务、下载模型或常驻 Node 进程。系统 [SQLite FTS5](https://sqlite.org/fts5.html) 提供 BM25；Vela 额外做确定性的 Unicode 折叠、CJK bigram、词覆盖和邻近度重排。原文保持不变，引用记录原文位置与版本 hash。此决定不把词面检索称为语义向量检索。

资料编辑、归档、恢复和重新抓取都要求最近审阅的 snapshotHash。归档保留原始资料和版本，默认搜索排除；源文件、URL 与 Vela 副本分开，编辑不回写外部来源。来源重抓是显式请求，失败保留旧版本；新版本与资料对象在同一 Store 事务内写入。没有模型处理或隐式远端请求。

段落索引是可重建的派生数据，与对象放在同一个 SQLite 文件中，通过独立的短连接和 SQLite 写锁协调。更新/删除触发器立即使旧段落失效；索引写入比较准确的原始对象快照，搜索重新核对当前对象和人工修改的 Markdown。private、归档、不合格路径和跨项目内容不进入检索结果；索引不是授权来源。索引状态和有界分页显式说明尚未索引的资料，不把部分覆盖称为完整。

拒绝两条更重路线：独立向量数据库增加运维成本且不能代替正确引用；每次问答递归扫描所有源文件使时间和隐私边界不稳定。文本提取继续使用 macOS PDFKit/textutil，并把实际支持格式与无文本 PDF 错误单独验证。YouTube、vault 监测、远端重抓队列和可选向量模型属于后续独立能力，不能由本次索引代称。

## English

Library edits, refreshes and reversible archival use reviewed hashes and retain versions. A rebuildable paragraph FTS5 index uses SQLite coordination, literal-safe queries, deterministic Unicode/CJK tokenization and local reranking. Retrieval revalidates current source content and privacy; stale or incomplete index coverage is observable. Original text and citation offsets are preserved. No downloaded model, remote search service or external source write is introduced.
