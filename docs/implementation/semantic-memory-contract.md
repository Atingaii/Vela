# Local semantic Memory integration contract / 本地语义记忆界面合同

2026-09-13。供 Antigravity 实现 UI 与 SDK/MCP 接入使用。核心位置：`SemanticMemory.swift`、`MemoryService.swift`、`Store.swift`。此文档描述接口，不代表 UI 已交付。

## 索引

调用 `memory.semantic.index`：

```json
{"project":"/registered/project","language":"en","batchSize":32}
```

`language` 仅 `en` 或 `zh-Hans`，默认 `en`；界面应让用户明确选择文本语言，不把应用显示语言静默当作文档语言。`batchSize` 为 1–200。第一次省略 `cursor`，后续原样传上次 `nextCursor`，直到 `hasMore=false`。只索引当前项目与允许共享的 global active Memory；私有、候选、归档和私有来源文件不参与。

正常返回 `status:ok|partial`、`model:{id,language,revision,dimension,runtime}`、`processed/indexed/unchanged/skipped/failed`、`nextCursor:string|null`、`hasMore:boolean`、`downloadRequested:false`。每批最多读取约 2 MiB Memory JSON；索引是可恢复的分批操作，不自动在启动/每次检索时重建。请求失败或页面关闭不意味着已索引记录回滚，不应盲目重试未知写入；可先查看 status，再从明确的游标或完整新遍历继续。

模型未安装时返回 `status:unavailable`、`model:null`、`reason`、`indexIncomplete:true`。没有自动下载、第三方模型或网络调用。UI 显示“本机暂不可用”，不显示成功或 0 个语义结果。

## 状态

`memory.semantic.status {project,language}` 返回：

```json
{"status":"ok","model":{"id":"apple.naturallanguage.sentence.mean512.v1","language":"en","revision":1,"dimension":512},"scanned":10,"eligible":8,"indexed":7,"stale":1,"missing":1,"indexIncomplete":true}
```

此 JSON 只示意字段，不是生产测量。真实维度/版本只能用当前响应。`indexed` 表示当前逐条来源/模型 metadata 对应的记录；`stale` 是有旧记录但摘要/模型不匹配，`missing` 包含 stale 与未索引。计数不是全局锁定快照；并发编辑可要求再遍历一次。所有页面处理完成不等同于 `indexIncomplete=false`，界面完成后再读状态。

## 召回

现有 `recall` 添加可选参数：

```json
{"project":"/registered/project","query":"车辆需要维修","retrievalMode":"semantic","language":"zh-Hans","minSimilarity":0.2,"limit":20,"budget":2000,"scoringWeights":{"semantic":1,"recency":0,"importance":0,"recencyHalfLifeDays":30}}
```

`retrievalMode` 仅 `lexical|semantic|hybrid`，默认词面检索保持原合同。`minSimilarity` 0–1，`limit` 1–100，`budget` 0–4000；branch/worktree/task/session 范围继续生效。权重 0–10，至少一个非零；半衰期 0.01–3650 天。默认只按语义相似度排序；日期或重要性缺失时该加权项为中性，不伪造观测值。

语义结果保留 `items/usedTokens/budget/truncated`，另有 `retrievalMode/model/indexCoverage/indexIncomplete/validVectors/staleVectorsExcluded/scopeExcluded/minSimilarity/limit/rankingPolicy`。每条可有 `semanticSimilarity`（cosine similarity）、`rankingScore`、`retrievalSource:semantic|lexical|semantic+lexical`。`limited` 表示超出 top-K，`truncated` 包含数量/预算截断；先取 top-K 再装入 token budget，预算可能有余量。不向 renderer 暴露向量 BLOB。不要把排名分值显示成模型置信度或质量改善百分比。

本机没有模型时：`semantic` 返回空 items + `status:unavailable`；`hybrid` 可返回词面结果，但明确 `requestedRetrievalMode:hybrid`、`retrievalMode:lexical`、`fallbackReason` 与 `model:null`。UI 应显示降级原因。若有模型但索引不完整，仍显示实际结果和“部分记忆尚未建立索引”。

SDK 接入层不建立 owner/delegate ACL。MCP 只扩展现有只读 Recall 的参数，不因新增语义检索自动获得索引写入权限。所有状态信息均取真实核心响应。

## English summary

Indexing is explicit, paginated, local, and restricted to active nonprivate Memory. The installed Apple sentence model and its actual language/revision/dimension are returned; no assets are downloaded. Recall defaults to lexical, supports semantic/hybrid modes, and reports incomplete/stale indexes and explicit fallback. Similarity and ranking scores are not confidence or improvement percentages. UI implementation remains assigned to Antigravity.
