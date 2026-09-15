# Semantic vector API / 向量公共合同

Status: implemented; installed-package acceptance receipts are recorded in [ADR 0031](../adr/0031-local-embedding-and-recent-matches.md#2026-09-13-installed-package-acceptance--安装包验收). Decision: [ADR 0031](../adr/0031-local-embedding-and-recent-matches.md).

All three methods use an explicitly registered `project` and the existing local JSONL RPC connection. They do not add MCP tools, accept shell/path primitives, start schedulers or write memories. Local process/filesystem authority still applies; a namespace is not a cryptographic ACL.

| Method | Input | Result |
| --- | --- | --- |
| `memory.semantic.embed` | `project`, `text` (nonblank, at most 65,536 UTF-8 bytes), optional `language` (`en` default or `zh-Hans`) | `status`, `model`, `vector`, `inputBytes`, `persisted:false`, `downloadRequested:false`; unavailable has `model:null`, no vector |
| `memory.semantic.query` | `project`, `model`, `vector`, optional scope/ranking parameters below | Current safe Memory records, cosine and ranking metadata, scope-specific index coverage and truncation; no implicit embedding or lexical search |
| `memory.semantic.recent` | `project`, `query` (nonblank, at most 16 KiB), optional `language` and scope/limit/threshold/budget | Same shape, fixed `sort:"recent"`; all qualifying semantic matches are considered before limit |

`model` is exactly `{id:string, language:"en"|"zh-Hans", revision:positiveInteger, dimension:integer1to4096}` and must equal the current provider, including Vela pooling algorithm version. `vector` contains exactly dimension finite numeric values convertible to Float32, with nonzero norm; boolean, null, strings, NaN, infinity, overflow and unknown identity fields fail. Vectors are normalized for cosine. Identity supplied by a caller is a compatibility claim, not authenticated evidence that Apple generated the vector. No uploaded vectors enter the persisted index.

Query/recent optional scope: `namespace` (nonblank, at most 256 UTF-8 bytes, no control characters), or `branch`, `worktree`, `task`, `sessionId` using existing matching rules. Namespace cannot be combined with those four fields; omitted namespace selects only permitted non-namespace project/global scope. A malformed scope never falls back to wider project scope. No `includePrivate`, `state`, `files`, arbitrary model/provider, or caller `now` field is accepted.

Ranking parameters: `limit` 1–100 (20), `budget` 0–4000 (2000), `minSimilarity` 0–1 (0.2, inclusive). Query also accepts `sort` (`relevance` default or `recent`) and `scoringWeights` only for relevance, following ADR 0013. Recent sorts valid nonfuture createdAt descending, then cosine descending, then stable ID ascending; missing/invalid/future dates are placed together after known dates. The response uses `rankingTimestamp` (or null) and `rankingTimestampState` (`valid`, `missing`, `invalid`, `future`), without inventing dates. Threshold filtering happens before ranking/limit, and token packing happens after top-K. A packed response may therefore use less than the available budget.

Responses explicitly mark `retrievalSource:"semantic"`, `querySource:"precomputed-vector"|"text"`, `sort`, `matchedVectors`, `validVectors`, `staleVectorsExcluded`, `scopeExcluded`, `model`, `indexIncomplete`, `indexCoverage`, `rankingPolicy`, `downloadRequested:false`. Scores are retrieval measurements, not probability or confidence. Index/source checks are per record; concurrent edits can make coverage change during the scan. Missing models return unavailable without lexical fallback. Query text/embedding input is not echoed or persisted by these APIs; callers own any logging or later sharing of returned vectors.

SDK names: TypeScript `semanticEmbed(text, parameters)`, `semanticQuery(embedding, parameters)`, `semanticRecent(query, parameters)`; Python sync/async `semantic_embed`, `semantic_query`, `semantic_recent`. Query takes the successful embed result's `{model,vector}` (it may be passed as a structural object; SDK forwards only those two fields). Errors retain existing typed transport semantics; all three are read-only so their own timeout/cancel does not claim a memory write. Cancellation terminates the owned local helper as already documented and does not revoke another independently dispatched write.

中文：此接口只处理显式输入和允许的当前 Memory；向量并非匿名数据，身份字段并非来源认证。Private Library 无读取入口，本次模型调用无网络、下载或持久化。远端 blob、所有 provider 和模型质量须独立验收。
