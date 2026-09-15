# Optional Walrus runtime contract / 可选 Walrus 运行合同

2026-09-13。本文描述当前已实现的 headless 可选 SDK 接口，供后续桌面适配使用。真实加密远端写后读与账户交易尚未验收；默认 Mac app 未引入 Node runtime，UI 不应显示已连接或已备份。第一方基线和剩余全集要求见 [审计](../parity/walrus-memory.md)，架构边界见 [ADR 0017](../adr/0017-optional-walrus-adapter.md)。

## Runtime and identity / 运行与身份

包为 `@vela-engineering/walrus@0.1.0-dev.1`，源码在 `sdk/walrus`，未发布 npm。复用 MemWal 0.1.6、Sui 2.5.0、SEAL 1.1.0、Walrus 1.0.3 的公开 API。每 client 按需一个 Worker；一次一个请求，2 MiB 协议帧，HTTP origin allowlist，无重定向，1–120 秒请求超时。close/cancel/timeout 终止 Worker，不代表远端回滚，不重发未知副作用。错误只有 code/requestID/effectsUnknown/httpStatus，无原始 SDK 错误/日志。

Profile 严格 version 1，包含 `id/mode/serverURL/network/fullnodeURL/packageID/sealPolicyPackageID/registryID/accountID/expectedOwner/namespace/allowedOrigins/writeLimits`；可选 `embedding/walrusAggregatorURL/sealServerConfigs`。仅 fixture 可显式允许精确 loopback HTTP，生产 HTTPS。`writeLimits` 为每实例次数/原文字节边界，不是费用或存储期限保证。不能自动补 mainnet、账户、namespace、私钥或默认原文接收方。

凭据由应用明确传入，SDK 不读取环境、文件、钱包、Keychain。远端 delegate 是账户级能力，namespace 是组织范围，不能显示成 namespace ACL。桌面接入仍需 Keychain 引用与明确钱包签署，renderer 不接收私钥。无账户公开 `/version` 和 `/config` 成功只代表 metadata 可读；`connect` 需当前节点 owner/type/active 与真正 signed metadata 成功。

## Exact API / 当前 API

| API | 行为与界面必须呈现的事实 |
| --- | --- |
| `compatibility`, `deployment` | 公共版本/部署 metadata，authenticated:false |
| `connect` | 当前链上 owner/type/active + signed metadata；不等于已存远端记忆 |
| `namespaces({cursor?,limit?})` | 实际 owner metadata 页；按 has_more/next_cursor，不靠页长猜完整性 |
| `recall(query,limit)` | 明确 mode、来源与有界结果；官方 Manual 吞错时 status:partial 和诊断数量，不用空数组伪装成功 |
| `prepareRemember(text)` | 纯预览，冻结原文/profile/namespace/接收者/id/10 分钟到期；storageEpochs 和 monetaryQuote 缺失为 null |
| `execute(preview)` | 仅本 client 存的相同预览，消费一次；accepted job 不等于 durable blob |
| `rememberStatus(jobID)` | 查询已知 job，禁止用重发 remember 代替状态恢复 |
| `prepareRestoreIndexRelayer(limit)` | 独立信任升级：relayer 将解密与 embedding；即使 clientEncryption profile 也须另行预览执行 |
| `prepareOwnerAction(input)` | createAccount/addDelegate/removeDelegate；必填 maxGasBudgetMIST，公开只读构建完整 bytes/digest/owner/next-epoch expiry；无 gas coin 不能提供可执行预览 |
| `executeOwnerAction(preview,signature)` | 钱包对精确 bytes 签名；官方签名验证后一次提交；SDK 不接收 owner 私钥用于此 API |
| `ownerTransactionStatus(digest)` | 当前链 effects / actual gas / created account IDs，缺失为 null，失败不冒充成功 |
| `createMemoryManifest`, `validateMemoryManifest` | 纯 version/schema/hash 校验，checksum 非 manifest 签名，非账户全集证明 |
| `restoreManifestPage(manifest,{cursor?,limit?})` | 端侧下载/SEAL 解密，只访问所选链、Walrus aggregator 和 SEAL；不访问 relayer/config/embedding，不重建远端 index |

`clientEncryption` 的官方 Manual remember/recall 仍将原文/query 发给显式 embedding endpoint；relayer 见密文/vector。`relayerProcessing` 允许 relayer 处理原文与短期 SEAL 授权。`restoreManifestPage` 是第三条明确端侧恢复路径，与 profile 普通写模式无关；不需要 embedding API key。

## Manifest and local review / Manifest 与本地审核

Manifest source 固定 `network/packageID/accountID/owner/namespace`，每项 `blobID/encoding/title/plaintextSHA256/plaintextBytes`。编码支持原有 MemWal `utf8-memory-v1` 与 `vela-memory-archive-v1`。已知预期摘要时必须核对；原有记忆无预期摘要时两个字段均为 null，不能虚构旧摘要。Manifest ≤1,000 项/512 KiB，单项明文 ≤1 MiB，每页 1–20 项且返回内容序列化预算 1.5 MiB。

端侧 reader 核对 account、signer owner/delegate、SEAL package、精确 namespace/owner identity 和非未来 access counter；公开 `SealClient.decrypt` 完成认证解密后再检查严格 UTF-8 与可选预期 SHA。每项失败带索引/blobID/code/retryable；cursor 绑定 manifest hash。覆盖信息为本页 start/end/total、pageAllRecovered、manifestTraversalComplete；账户全集始终 unknown。到达末页不表示之前失败页已修复。

每个 recovered 项包含 `text/sha256/bytes/source` 与 `receipt`：`sealAuthenticated/expectedChecksumVerified/actualSHA256/plaintextBytes/manifestSHA256/manifestAuthenticated:false`。其中 manifest checksum 不是签名，所有证据仍依赖用户选定的节点和真实 SEAL 协议。

原始文本通过本地 SDK `archiveFromWalrusRecords` / `archive_from_walrus_records` 调用 Core `memory.archive.fromWalrusRecords`。输入 source、records 和 intendedUse:candidate-review；每 record 明确 blobID/title/content/sha256/private:false，可带 reader receipt。Core 不联网、不写记忆，只核对输入哈希并用 Foundation 规则生成 V1 archive。远端 source 使用 `/external/walrus/<source-hash>` 虚拟 provenance，永不解析为本地读取路径。Receipt 保留在 sourceMetadata 内并明确 caller-reported / remoteAuthenticationVerifiedByCore:false。然后显式 validate/import 到已注册项目，原子、候选、同源同版本幂等；激活属于另一个用户审核动作。

Vela archive 编码先 JSON 解析，再用 Core 完整 validate/import；reader 仅检查编码标记，不能替代 Core schema/record/outer checksum。以上两条都不恢复私有完整库或原始 active 生命周期。私有全备份需要独立 state-preserving container，禁止进入 Agent 召回。

## Verification and remaining acceptance / 验证及剩余验收

已安装官方 SDK fixture 与类型检查通过；无账户公共 mainnet/testnet preflight 成功。一次性隔离 testnet owner 已生成，当前 package/registry 通过公开发布交易和链对象核对。官方免费 faucet 返回 429，实测余额为 0；因此 gas payment refs、真实 owner 提交、远端 durable write 和成功 SEAL 解密仍未验收。具体公开准备见 [账户测试计划](walrus-account-test-plan.md)。不读取现有用户钱包，不花真实币。

下一端到端验收仍是：明确账户/namespace → 精确交易预览 → 新 delegate → synthetic remember → durable job/blob → 全新 store 端侧解密与 SHA → candidate → 审核 → Recall。随后验证撤销/轮换、恢复失败重试/分页、索引丢失、期限/续期/删除、私有备份与各 SDK/MCP/client integrations。未通过的步骤继续显示为未验收。

## English summary

The optional headless adapter has explicit reviewed remote actions, exact owner transaction signing, and a separate public-SEAL manifest reader supporting original UTF-8 memories and Vela archives. Remote source and recovery receipt claims passed to local Core remain caller-reported; Core checks plaintext hashes and produces candidate archives without network or writes. Installed protocol fixtures do not replace actual chain and encrypted-storage acceptance. Free testnet funding is currently rate-limited, with zero gas coins observed. Desktop credential integration, private/full backup, and the remaining audited capabilities remain required work.

## Bulk and metadata extension / 批次与元数据扩展

`prepareRememberBulk(texts)` freezes 1–20 selected-namespace texts; every item consumes an operation, total plaintext <=1 MiB and per-item <=64 KiB. Only relayerProcessing is supported for this official bulk path. The returned `items[index].jobID` preserves input order and is not a durable receipt. `rememberBulkStatus` queries 1–20 unique job IDs and restores request order; unknown/failed/pending are separate. `waitForRememberJobs` performs bounded read polling (<=120 seconds), does not retry writes and reports that original jobs are not canceled.

`ownerMemories` exposes metadata-only owner scope, snapshot v2, additive tombstones and mandatory mustResync. Cursors wrap the opaque server value with a frozen deployment/account identity. An empty page can still have a cursor; hasMore controls traversal. `ownerAgents` is the relayer's cached on-chain projection, not live proof of every revocation. `namespaceStats` requires actual nonnegative integer counts/bytes. `prepareForgetNamespace` freezes index-only deletion for the selected namespace with explicit retained-Blob and separate-restore semantics.

These methods reuse public SDK bulk submission and documented fixed signed REST routes for metadata/status/forget. The public SDK lacks several methods and sends SEAL sessions on status by default; metadata routes deliberately use only public Ed25519 signatures, never SDK private methods or decrypt credentials. Worker origin/size/owner/version bounds still apply. Real protocol fixtures establish request shape and signature correctness; actual funded remote durable writes, tombstone propagation and complete restore remain separately unaccepted.
