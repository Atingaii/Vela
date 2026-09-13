# Vela optional Walrus adapter

An explicitly enabled Node.js 22+ adapter using the published official Walrus Memory SDK. This package is separate from the Mac app and local Vela SDK. It is **not published to npm**. Construction and ordinary write previews perform no network requests. Owner preparation performs only explicit public chain/deployment reads to build exact transaction bytes. Remote encrypted storage has not yet passed an account-backed end-to-end acceptance test.

```sh
npm ci
npm run build
npm test
npm pack
```

```ts
import { WalrusClient, type RemoteProfile } from '@vela-engineering/walrus';

// Obtain these public settings from the chosen deployment; no default account,
// network, namespace, embedding recipient, storage quote or funding assumption.
const profile: RemoteProfile = {
  version: 1, id: 'my-test-deployment', mode: 'clientEncryption',
  serverURL: 'https://chosen-relayer.example', network: 'testnet',
  fullnodeURL: 'https://chosen-sui-node.example',
  packageID: '0x' + '1'.repeat(64), sealPolicyPackageID: '0x' + '1'.repeat(64),
  registryID: '0x' + '2'.repeat(64), accountID: '0x' + '3'.repeat(64), expectedOwner: '0x' + '4'.repeat(64),
  namespace: 'chosen-project',
  allowedOrigins: ['https://chosen-relayer.example', 'https://chosen-sui-node.example',
    'https://chosen-embedding.example', 'https://chosen-aggregator.example'],
  embedding: {endpoint: 'https://chosen-embedding.example/v1', model: 'explicit-compatible-model', plaintextRecipientAcknowledged: true},
  walrusAggregatorURL: 'https://chosen-aggregator.example',
  writeLimits: {maxOperations: 1, maxPlaintextBytes: 65536},
};
// IDs/URLs above are explanatory placeholders, not a deployable profile.
const client = new WalrusClient(profile); // No credential needed for /version.
try {
  const compatibility = await client.compatibility(); // authenticated is false.
  const preview = client.prepareRemember('Synthetic text selected for review.');
  // Display the entire preview and recipients. This does not execute a write.
  // In an explicitly credentialed client, create and review its own preview,
  // then execute that same client's unchanged preview once.
} finally {
  await client.close();
}
```

A preview belongs to the client that created it; it cannot be moved to another client or reused. For an actual reviewed operation create the client with explicit `{delegateKey: Uint8Array(32), suiPrivateKey?, embeddingApiKey?}` supplied by the application, then prepare and execute on that same client. No environment, filesystem credential store, wallet, account or Keychain is automatically read. Keep credentials out of CLI arguments and profile JSON. The desktop integration's Keychain reference and wallet approval flow are still pending.

`compatibility`, `deployment`, `connect`, `namespaces`, `recall`, `rememberStatus`, `prepareRemember`, `prepareRestoreIndexRelayer`, `prepareOwnerAction`, `executeOwnerAction`, `ownerTransactionStatus`, `restoreManifestPage`, `execute` and `close` call public official SDK APIs or enforce local review boundaries. `deployment` reports public deployment settings without authenticating. Every protected request and any SDK internal `/config` refetch must match the frozen package/network; a relayer owner substitution is rejected before signing another owner's metadata request. `connect` freshly checks the selected fullnode's account owner/type/active state and performs a signed relayer metadata read. Namespace is an organization boundary; account-wide delegates are **not** isolated by namespace ACL. Identity evidence relies on the explicitly selected fullnode/relayer, not a new independent light client.

`clientEncryption` uses the official Manual SEAL path: the relayer receives ciphertext and vectors, while the selected embedding endpoint receives plaintext/query. The published SDK provides no public embedding callback; this package does not patch its private methods or claim Apple vectors are compatible with the remote index. All necessary SEAL/Walrus/Sui endpoint origins must be explicitly allowed. An unexpected origin, redirect, oversized request/response or missing credential fails instead of silently changing mode.

`relayerProcessing` permits the selected relayer to process plaintext and ephemeral SEAL session material. `prepareRestoreIndexRelayer` is a separate explicit trust upgrade even for a client-encryption profile. Its execution uses the official relayer-mode restore method. The returned `complete: "unknown"` is intentional: a bounded restore and `truncated: false` do not prove a complete Blob inventory. Client-side manifest recovery now uses public SEAL APIs independently of the relayer and embedding service; its successful real-network decrypt still needs account-backed acceptance. Private/full-store backup remains a required separate implementation. Owner create/add/remove delegate interfaces are implemented with official builders and signature verification; real funded transaction build/submission remains unverified. Local archives do not substitute for those acceptance checks.

The official manual relay request does not carry its `walrusEpochs` config to the upload relayer. Previews therefore report `storageEpochs: null` and `monetaryQuote: null`. `writeLimits` enforce cumulative operation count and plaintext bytes for this client instance; they are not a persisted account balance, gas cap, storage-duration promise or embedding-fee guarantee. A new client has a new local allowance. Real test-account setup, fees, funding and storage terms require a separately reviewed concrete operation.

Prepared actions freeze profile, namespace, text, recipients, operation ID and a ten-minute expiry. `execute` compares the complete frozen representation and consumes the action before dispatch. Timeout, cancellation or an uncertain remote error never restores its approval. `prepareOwnerAction` accepts createAccount/addDelegate/removeDelegate plus an explicit `maxGasBudgetMIST`, builds complete transaction bytes using public chain reads, fixes sender/gas cap/next-epoch expiry, and returns a reviewable preview. It needs no owner private key. Only `executeOwnerAction(preview, serializedSignature)` can submit it: the exact bytes/digest/gas cap/owner signature are verified, then the action is consumed once. `ownerTransactionStatus` queries the known digest after uncertain outcomes. Incomplete transaction building cannot become an executable approval. The selected wallet remains responsible for signing.

The relayer remember route receives the stable operation ID as its public SDK idempotency key; the manual SDK has no equivalent public parameter. Accepted job IDs are distinct from completed Blob results. Use `rememberStatus` to inspect an existing job; no mutation is automatically retried.

The published Manual SDK suppresses some recall/decryption failures after logging them. The isolated worker counts those diagnostics without formatting or retaining their arguments. A recall with suppressed diagnostics returns `status: "partial"` and `suppressedDiagnosticCount`; an empty result is not presented as verified absence. An `ok` result is still bounded, not a complete account inventory.

Each client lazily creates one isolated Worker. Every fetch stays within declared origins, rejects redirects and bounds request/response bodies to 2 MiB. Console/stdout/stderr are discarded with a 64 KiB combined limit. One request is in flight; others receive `busy`. Timeout is 1–120,000 ms, default 15,000. Close/abort/timeout terminates the Worker and its fetches; this cannot undo work accepted by a remote server. `WalrusError` exposes only `code`, `requestID`, `effectsUnknown`, and `httpStatus`, never a raw SDK error/cause or secret response body. Key buffers are cleared when possible; JavaScript strings/heap copies cannot be promised to be securely erased.

Dependencies are pinned in the lockfile: official MemWal 0.1.6, Sui 2.5.0, SEAL 1.1.0 and Walrus 1.0.3. Sui's public `SuiJsonRpcClient` is injected because the legacy `SuiClient` export is absent even in this pinned release. Dependency licenses remain their own; Vela's adapter code is MIT. Do not confuse compatibility baseline 0.0.4 with package version 0.1.6.

## 简体中文

这是可选的官方 Walrus SDK 接入包，不进入默认 Mac 安装包，没有发布到 npm。配置、账户、网络、namespace、允许访问的服务与原文明文接收方均需显式指定。构造和普通写入预览不联网；Owner 预览为冻结完整交易，只读显式选定的链与部署；配置不保存私钥，也不自动寻找用户现有凭据。

客户端加密仍会向选定的 embedding 服务发送原文，relayer 模式则允许服务端处理原文。服务端索引恢复是单独的信任升级，必须重新生成完整预览并明确执行，不能在后台自动发生。namespace 不是 delegate ACL。端侧 manifest 恢复已用公开 SEAL API 实现，成功解密仍待真实账户验收；私有完整备份仍须独立实现。Owner create/add/remove delegate 已封装公开 builder、完整 bytes 冻结及钱包签名验证；真实 gas/object refs 构建、提交与付费账户闭环仍须逐项验收，不因合成签名测试通过就标记链上成功。

写入严格冻结参数、一次执行、过期失效；不确定结果不重试，已经接收的 job 用状态查询恢复。数量和字节限制只针对当前 client 实例，不冒充账户资金/费用/存储期限上限。原始 SDK 异常和日志不会返回给调用者。测试分别标记真实官方 SDK 协议 fixture、安装包验证和真正远端账户测试。

官方 Manual SDK 会记录后吞掉部分召回/解密错误。适配器只计数而不保留这些日志参数，并将相应结果标为 `partial`，不把空数组当作验证无记忆。

## Client-side manifest recovery / 端侧 manifest 恢复

`createMemoryManifest(source, entries)` and `validateMemoryManifest(manifest)` are pure, strict version-1 operations. The source binds network/package/account/owner/namespace. Entries select immutable `blobID`, `encoding` (`utf8-memory-v1` or `vela-memory-archive-v1`), `title`, and either a known `plaintextSHA256` plus `plaintextBytes`, or both `null` for existing MemWal records without a prior plaintext digest. A checksum is not a manifest signature or proof of a complete remote inventory. Limits are 1,000 entries and 512 KiB manifest; plaintext is bounded to 1 MiB per entry, with a 1.5 MiB serialized result budget per page.

Configure explicit `walrusAggregatorURL` and `sealServerConfigs: [{objectID, weight, aggregatorURL?}]` in the profile, with every network origin allowed. `restoreManifestPage(manifest, {cursor?, limit?})` needs an explicit Sui signer, but no embedding API key. It calls only the configured chain, aggregator and SEAL servers: no `/config`, relayer restore, re-embedding or index write. Page size is 1–20. Cursors bind the manifest hash. Each page reports recovered entries, individual failures, retryability, next cursor and exact coverage; reaching the end is not proof that earlier failed pages succeeded or that all account blobs were inventoried.

The reader checks current account owner/type/active state and the signer's owner/delegate address, exact namespace/owner SEAL identity and a nonfuture rotation counter, then uses public `SealClient.decrypt`. Authenticated decryption, fatal UTF-8 validation and any expected plaintext checksum must pass before returning content. The receipt distinguishes `sealAuthenticated`, `expectedChecksumVerified`, the actual digest/bytes, and the unauthenticated manifest checksum. No plaintext goes to an embedding service during this path.

For `utf8-memory-v1`, pass the recovered source and explicitly selected non-private records to the local SDK's `archiveFromWalrusRecords` / `archive_from_walrus_records`, then validate/import its archive into an explicitly selected registered project. Include the reader's receipt to retain its reported verification state. Core verifies the supplied plaintext SHA and constructs canonical checksums; it **does not authenticate the caller's remote-source or receipt claims**. Import is candidate-only, atomic and idempotent for the same source version. For `vela-memory-archive-v1`, parse the recovered text, then use local `validateArchive` and `importArchive`. Neither path automatically activates memory or restores private/full-store state.

Manifest 恢复无需 embedding API key，也不接触 relayer。原有 MemWal 未保存预期明文摘要时可以显式传 null；解密后计算实际 SHA，并清楚标记未核验预知摘要。每项 receipt 与分页 coverage 分开记录，不用“到达最后一页”替代全部成功。Core 构造 raw 文本归档只核验内容哈希，不把调用方自报的 SEAL 认证当作 Core 已证实的事实。

### Explicit fact extraction

`prepareAnalyze(text)` is available only in `relayerProcessing` mode. Review the frozen action before `execute`; it sends the selected plaintext and a short-lived official SEAL session to the named relayer using MemWal 0.1.6 `analyze`. The returned facts and job IDs mean accepted work, not confirmed durable storage. No published analyze idempotency option exists, so this adapter never invents one or retries an uncertain write. The OpenClaw plugin adds a persistent attempt journal and explicit unattended plaintext consent/caps.

中文：事实提炼需明示 relayer 接收明文，accepted jobs 不是持久化成功；没有伪造官方 API 不支持的幂等参数，未知副作用不自动重发。

### Bulk, incremental metadata and index deletion

Use `prepareRememberBulk(texts)` for 1–20 texts in the selected namespace, then execute its frozen action once. Each item counts against the operation cap. The published SDK handles accepted job IDs; accepted is not durable, and bulk has no public idempotency argument. `rememberBulkStatus(jobIDs)` returns requested order with separate done/failed/missing/pending counts, without forwarding raw failure text. `waitForRememberJobs(jobIDs, {maxWaitMs, pollIntervalMs})` bounds read polling; timeout or cancellation never cancels the original writes. Keep accepted IDs to resume status reads after reopening a client.

`ownerMemories({cursor,limit})` explicitly lists owner-wide metadata, including deletion tombstones and `mustResync`; `ownerAgents()` lists the owner's delegate projection. Both expose metadata only. A Vela cursor binds the server's opaque cursor to endpoint/network/package/account/owner. Stop traversal using `hasMore`, retain the final cursor for later incremental polling, and discard incremental state if `mustResync` is true. Page length is never a completion signal. API snapshot versions other than the audited v2 fail explicitly. `namespaceStats()` returns measured count/bytes; missing values are errors, not zero.

`prepareForgetNamespace()` reviews deletion of only the selected namespace's vector index rows. Encrypted Walrus blobs remain; rebuilding their index requires a separate restore action and its trust decision. This is not permanent deletion. These fixed metadata/status/forget endpoints use the documented public signing protocol and Sui's public Ed25519 signer; they never call private SDK methods or transmit SEAL/delegate decryption credentials. Public 0.1.6 lacks metadata/forget methods, and its status wrapper unnecessarily attaches a SEAL session, hence this separate metadata path.

中文：批次每条计入预算；接收任务不等于持久存储。状态查询区分完成、失败、缺失与仍在处理，保留任务 ID 可重开查询。owner 元数据不是 namespace ACL，删除 tombstone 与过期 cursor 的 mustResync 都保留。forget 只删索引、不删 Blob，恢复必须独立显式操作。元数据路径不授予远端解密权限。
