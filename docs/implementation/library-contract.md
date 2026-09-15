# Library 管理与段落检索合同

这是当前开发源码的合同，不代表已发布安装包。没有隐式模型调用、嵌入模型下载或远端索引服务。界面由 Antigravity CLI Gemini 3.8 Flash High 实现。

## 管理入口

`library.add` 保留兼容的 create-only 行为，参数为 `{id?,title,project?,content?|path?|url?,private?,folder?}`。content/path/url **必须且只能选一个**。默认 private=true。folder 是资料集内逻辑分类（如 `engineering/parser`），不能含绝对路径或 `..`。标题最多300字符，文件与提取正文上限2 MiB。未知字段/非布尔 privacy 拒绝。显式文件导入记录来源路径与当时内容 hash，导入/编辑不修改外部源文件。

| 方法 | 参数 | 返回/作用 |
| --- | --- | --- |
| `library.list` | `{project?,includeArchived?}` | 原有数组；默认隐藏归档 |
| `library.get` | `{id,project?}` | `{item,snapshotHash}`；当前受限读取的 Markdown；文件丢失/不安全明确错误 |
| `library.update` | `{id,project?,snapshotHash,title?,content?,private?,folder?}` | 新版本；不能移项目或改外部来源身份 |
| `library.remove` | `{id,project?,snapshotHash}` | 可恢复归档；保留版本，默认检索排除 |
| `library.restore` | `{id,project?,snapshotHash}` | 恢复 Active 资料，保留私有状态 |
| `library.refresh` | `{id,project?,snapshotHash}` | 明确重新读取原文件/URL；有新版本，失败保留旧内容；纯文本条目没有可重抓来源 |
| `library.history` | `{id,project?}` | 该来源的版本数组，包含 change/sourceId/version；当前上限10,000，不伪称无限历史 |
| `library.export` | `{id,project?}` | `{content,filename,snapshotHash,private,writesSource:false}`；返回 Markdown，由原生另行选择保存位置 |

project 必须与条目作用域一致；全局资料需省略 project，不能通过另一个项目读取或改变。变更需最近 get 的 snapshotHash，过时后重新审阅，不自动替换 hash 重试。历史和人类显式导出可以包含私有资料；不能把它们转发给 Agent。private/.private 来源标签（包括选择路径中的别名标签）强制私有。公开检索要求 private 为明确布尔 false，缺失、字符串、数值或不明确来源标签均不当成公开许可。

## 本地段落检索

`library.index {project,cursor?,batchSize?}` 为显式有界任务，默认每页25、最大100条。返回 `{processed,indexed,unchanged,excluded,failures,nextCursor,pageSucceeded,indexVersion,networkRequests:0}`。客户端逐页处理，取消时停止发下一页；已处理页保留。failures 不得被成功提示覆盖。private/归档不索引；来源删除或改变时旧段落失效。

`library.index.status {project}` 返回 totalDocuments、eligiblePublicDocuments、indexedPublicDocuments、pendingDocuments、databaseCoverageComplete、assetEditsChecked、backend。databaseCoverageComplete 只表示已观察数据库版本的覆盖；外部手改在索引和候选读取时核验，不能从此字段声称磁盘上所有源文件已实时扫描。

`library.search {project,query,k?,rerank?,kind?}`，k默认10、1–50；kind只支持`library`，错误类型明确拒绝。查询最多1,024 UTF-8字节、64个检索词。安全字面词查询，不执行用户输入的 MATCH/SQL/通配运算。默认对最多200条 BM25 候选做词覆盖、邻近度重排，rerank=false可比较原始 BM25 排序。结果含 candidateCount/candidateLimit/candidateLimitReached/staleSourcesExcluded/index，截断必须可见。

每个 item 都是实际原文段落：

```text
id, kind="library", project, title, content,
sourceHash（完整正文）, sourceSnapshotHash（对象版本）, excerptHash,
anchor, citationId, heading, rangeUTF16={location,length},
sourceURL|null, sourcePath|null, bm25, coverage, proximity
```

UTF-16 range 可由客户端准确定位原文；中文、emoji组合字符、重名标题与重复段落不生成重复 citationId。展示原文和来源；不得把检索分数包装成答案正确率。Unicode 重音折叠与 CJK 字符/bigram 仅用于索引，正文不变。当前为词面段落检索，语义 Memory 的本地模型是另一入口；无 Library 向量能力时不能显示已启用。

支持显式 UTF-8 文本、Markdown、RST、Org、HTML、可提取文字 PDF，以及系统 textutil 能提取的 DOC/DOCX/ODT/RTF；无文本 PDF 明确要求先 OCR。URL读取仅由用户显式导入/重抓触发。YouTube/playlist、vault实时监测、远端全库重抓队列不属于本合同，不由本地索引代称。

## English

Library management retains immutable versions and uses reviewed hashes for edits, archival, restoration and explicit source refresh. Imports select exactly one source and default to private; no external source is overwritten. Public paragraph retrieval revalidates managed assets, content hashes, privacy and scope. FTS5/BM25 plus deterministic Unicode/CJK lexical reranking returns real paragraph citations and bounded coverage metadata. Indexing is explicit and resumable by page, and has no model download or network request.
