# ADR 0031: Explicit embedding and newest semantic matches / 显式向量与新近语义匹配

- Status: Accepted; implementation acceptance is recorded separately
- Date: 2026-09-13
- Scope: WM-07 / WM-08; Core and optional local TypeScript/Python SDKs

## Reference / 固定合同

MemWal commit `493c9e66851e1b542ce5f55a547827f64e141c45` documents [`recent`](https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/api-reference.md#ordering): cosine candidates widen to `max(limit, min(limit * 5, 50))`, then write-time descending, with cosine as the timestamp tie-break. Weights only reorder the selected candidates. Its [relayer reference](https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/relayer/api-reference.md) exposes signed `embed` for non-empty text up to 64 KiB without persistence, and manual vector search returning blob hits for client-side download/decryption. The installed official SDK `@mysten-incubation/memwal@0.1.6` actually exports these methods; `recallManual` accepts vector, limit, namespace and scoring weights, but no public sort option. Live docs.wal.app could not be retrieved in this verification; the fixed first-party repository and installed release establish this baseline.

## Decision / 决策

延续 ADR 0013 的系统 NaturalLanguage 和 SQLite。新增独立只读 `memory.semantic.embed / query / recent`，不改变既有默认词面召回、MCP 目录或 UI。embed 仅处理调用者显式提供的文本，不接受 Memory ID、文件路径、Library 记录或自动采集源。正文和向量不写入 Memory、索引或审计记录；结果不回显正文，也不生成可被用于离线猜测的正文摘要。向量仍可能透露文本特征，不能当作匿名数据。

模型身份由 algorithm ID、language、实际 revision 和 dimension 共同确定。`apple.naturallanguage.sentence.mean512.v1` 明确包含 512 Unicode scalar 分块、逐块归一、均值池化及最终归一的算法版本，不把同维向量视为同模型。已有 Apple provider 在调用时才加载；不可用返回 unavailable，不下载、不猜测、不发网络请求。人工预计算向量按 Float32 规范检查维度、有限值和非零范数，并要求身份等于当前 provider。Core 能验证身份兼容与数值，不能认证调用者声称的生成来源。query 不重新嵌入文字，也不把词面分加进向量结果。

query/recent 都先逐项复核 project/namespace、Active、非 private、当前 managed source 与索引 sourceHash/model identity，再过 inclusive cosine threshold。scope 参数严格校验，namespace 模式不能混合 branch/worktree/task/session；普通项目模式不包含 namespace。index coverage 只统计该查询实际允许的 scope，不能通过统计暴露另一个 namespace 的数量。private Library 不属于查询数据源。

`recent` 在所有通过范围与语义阈值的当前有效向量中选最新匹配，使用记录 `createdAt`，不是正文描述的事件时间或本次索引时间。与参考最多 50 个 cosine 候选相比，本机精确流式扫描不因该候选窗口漏掉新近匹配，但为 O(N) 扫描，不保证大库延迟领先。合法且不晚于本次统一 now 的时间在前，缺失、无效和未来时间共同置后；相同时间按 cosine 降序，再以稳定 Memory ID 升序。每项标注时间状态。recent 拒绝 scoringWeights，避免一个参数承诺新近排序、另一个又覆盖它。

query 默认为 relevance，可明确选择 recent。relevance 支持已有 cosine/recency/importance 公式；评分是排名而非置信度。所有模式只保留 limit 个候选，再执行原 token packing，报告阈值、匹配数、limited/truncated、scope/index coverage 和排序规则。有效索引缺失或 stale 时明确 incomplete。时间可由 Core 测试注入，生产只有一次 Date()；public API 不接受伪造 now。

## Alternatives / 取舍

沿用文字 recall 并让客户端自己排序会在截断后遗漏新记录，也无法处理只持有向量的调用者。将任意外部 vector 写进索引会引入模型污染和来源权限边界；此次只接受查询向量。新增远端 embedding 服务会引入凭据、成本和正文出站，与这次本机入口无关；未来远端 provider 必须另行明确授权。当前不引入持久服务、新表或默认 SDK 运行时。

## Acceptance / 验收计划

真实安装的 TS/Python 包调用 source-frozen helper；实际 Apple en/zh-Hans embed→query→recent，明确报告模型不可用的主机。确定性小向量只验证排序、时钟、scope、source freshness、模型/维度/NaN/布尔/零值负例，不能充当语义模型质量证据。验证 embed 零 Memory/索引写入、跨项目和 namespace、不混 Private/非 Active/改动源、重启读、取消/close、严格参数和包内类型。保留精确源/hash、包/hash和独立收据，不把本地 Memory ID 称为 Walrus blob ID，不据此关闭远端/多客户端未验收条目。

## 2026-09-13 installed-package acceptance / 安装包验收

基于 `365ed41325dcaf9f0c8a41e216ca29be9d91ba3f` 的 `git archive` 建立独立 stage，只覆盖本 ADR 所有的 Core、SDK、测试和合同文件。该 stage 的 frozen helper SHA-256 为 `8aed8d31c40167d1e537afed2d46658256c3a2119ce4e8afd00181287f5b63d7`。`npm pack` 安装的 TS tarball `vela-engineering-sdk-0.1.0-dev.1.tgz` SHA-256 为 `ea9a992e98d11ecf496ca853cc054c897bc2f373cce3e9d7d487605ae2303856`，在临时 consumer 外部导入、严格 `tsc` 和 13 项 Node 测试通过。临时 venv 安装的 Python wheel `vela_engineering-0.1.0.dev1-py3-none-any.whl` SHA-256 为 `72f312dca677728dad76a3e6bb615cd0b39c6fa3eda2975128e415f5ecd20dfd`，14 项同步/异步测试通过。两者均实际执行 explicit embed→precomputed query→recent，并覆盖 64 KiB 拒绝、无持久化、namespace 隔离、namespace/branch 混用拒绝、source 编辑失效和 recent 权重拒绝；模型缺失时仅验收明确 unavailable 路径。

Core 的 [portable receipt](../parity/semantic-vector-sdk-core-portable.json) 固定 7 个 `SemanticVectorAPITests` 方法及完整输入 hash，`snapshotSHA256` 为 `471928dd7592dfd00b3b3ee063b5f3b738582d9f5b43691bfd7cc45d2474e330`，全部通过。此主机仅有 Xcode Command Line Tools，`swift test --filter SemanticVectorAPITests` 在编译测试 target 时缺少 `XCTest`，因此该收据是同一同步 test body 的 portable assertion fallback，不能称为 XCTest。首次 Python wheel 运行曾错误拒绝完整的 embed 成功响应；保留的 [初次失败收据](../../output/parity/semantic-vector-sdk-acceptance-initial-python-structural-rejection/) 对应修复前的结构兼容问题，最终通过收据在 [SDK acceptance receipt](../../output/parity/semantic-vector-sdk-acceptance-final/)。本地 Apple embedding 的此类合成 consumer 场景不证明通用模型质量；没有发起 Walrus 远端写入、加密存取或账户操作。

## English summary

Three explicit read-only APIs expose local embeddings, compatible precomputed-vector queries and newest-among-semantic-matches ordering. The system model is optional and never downloaded. Every query retains fresh-source, project, namespace and privacy checks. Recent ordering scans all qualifying vectors before top-K, with deterministic timestamp/similarity/ID ordering and no lexical fallback. This is local API parity and an explicit candidate-window improvement, not encrypted-remote compatibility or proof of caller vector provenance.
