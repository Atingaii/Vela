# ADR 0017: Optional Walrus adapter / 可选远端记忆适配器

- Status: Accepted
- Date: 2026-09-13
- Scope: Optional SDK runtime, explicit remote data/credential boundary, reviewed remote operations

## Context / 背景

完整参考能力覆盖需要加密远端持久化、真实 owner/namespace/delegate 与跨设备恢复。已交付本地 Archive、SDK 和 Apple 语义检索不能代替这些能力。官方 SDK/协议已有账户和 SEAL 实现，重写加密合约或部署一套新记忆服务会增加风险与长期成本。详细来源和逐项缺口见 [完整审计](../parity/walrus-memory.md) 及 [远端合同](../implementation/walrus-remote-contract.md)。

## Decision / 决策

使用独立可安装 `sdk/walrus`，固定官方已发布 MemWal 0.1.6、Sui 2.5.0、SEAL 1.1.0、Walrus 1.0.3。锁定 npm transitive dependencies，以实际包类型/行为作为调用依据。这个 Node 包不加入默认 Mac bundle，也不让本地会话/Memory/SDK/Workflow 自动联网。未来桌面接入需要显式 helper 与 Keychain 引用；若将 runtime 分发至桌面需另评估包体/运行边界。

公开 profile 完整列出网络、relayer、Sui 节点、合约/账户/预期 owner/namespace、embedding 与 Walrus 接收方和允许 origins。没有隐式 mainnet、namespace 或 embedding provider。只有本地测试选项可开放精确 loopback HTTP，远端要求 HTTPS，拒绝带凭据 URL 和所有重定向。credentials 只由调用者明确传入，不读取 environment/files/Keychain。owner/delegate 的链上权限与 namespace 组织分区区分，SDK 不是 namespace ACL。

区分 `clientEncryption` 和 `relayerProcessing`。前者使用公开 Manual API 本机 SEAL 加解密，但其 embedding API 看得到原文；后者允许服务端处理原文及短期 SEAL 会话凭据。官方 Manual 没有公开本地 embedding callback，不能私自 patch `embed`；官方低层 encryptedData/vector API 将用于以后明确的本地 embedding/SEAL 路径，并首先解决远端索引维度/版本兼容。

`prepareRestoreIndexRelayer` 生成独立显式信任升级预览，执行时使用 relayer SDK，不把 Manual.restore 命名为端侧恢复。结果 `complete:unknown`，因为官方 newest-N/sidecar 上限不能证明全集恢复。完整端侧 Blob manifest 恢复需要另外落地并真实验收，仍在用户要求范围内。

profile 与公开写操作参数通过 deterministic JSON 冻结；保存前深复制全部嵌套参数，防止调用者随后修改原始数组改变实际请求。预览包含原文/namespace/接收者/operation ID/十分钟有效期，执行仅接受本 client 保存的完全相同预览，消费一次。prepare 不联网，execute 不自动重发；超时/取消/核心未知错误保守报告 `effectsUnknown`。relayer remember 采用已发布 SDK 的显式 idempotency key；manual 未公开该参数，不注入未知字段。

官方 manual 发往 relay 的请求没有 `walrusEpochs`，因此预览中的真实费用与期限为 unavailable/null，不能拿配置值冒充实际持久化合同。当前 writeLimits 是本 client 的次数/字节边界，不是跨实例账户费用限制或 durable journal。真实费用/上传在合成数据与可审阅调用准备完成之后再由用户决定。owner 交易使用独立 prepare/executeOwner 入口，必填 gas cap，并冻结完整 transaction bytes/digest/next-epoch expiry。官方 account builder 在公开 walletSigner callback 被截获，不签名或提交；真实节点只读构建完成后才可批准。提交由调用方钱包提供 serialized signature，经官方 verifyTransactionSignature 验证后发送一次，SDK不需要 owner 私钥。已封装 create/addDelegate/removeDelegate，真实 funded chain 验收仍待执行。

一个 client 按需创建一个 Worker，所有官方调用在隔离上下文内运行，不修改调用方 global fetch，也不访问 SDK 私有方法。Worker 中对公共 fetch 施加 origin/禁止重定向/2 MiB body 限制；错误只返回固定 code/status，stdout/stderr 丢弃并有 64 KiB 总限制。一时只允许一个进行中请求。close/timeout/cancel 终止 Worker，已被服务端接收的操作仍可能完成，不宣称远端回滚。密钥 byte buffer 可清空；JS string/heap 副本不提供可证明擦除保证。

公开 `/config` 仅返回限定部署 metadata，未鉴权。每个受保护操作及官方 SDK 的后续 `/config` 再次读取必须匹配被冻结的 package/network；防止先通过 preflight 再换 SEAL package。SDK 解析 stats owner 前同样拒绝 owner 替换。每个受保护操作再经公开 SuiJsonRpcClient 查询 account type/owner/active；账户与声明预期 owner 不符就不继续 relayer 请求。再通过官方真实 Ed25519 signed metadata/query API。`compatibility` 不鉴权，成功不代表账户已连通。`connect` 需链上读取和签名读均成功才给出 authenticated。此证据依赖用户选择的节点，不冒充独立链上轻客户端证明。

## Alternatives / 取舍

### Bulk jobs and owner metadata (2026-09-13)

Add frozen `prepareRememberBulk` and `prepareForgetNamespace` actions, bounded bulk status/wait and explicit owner memory/agent metadata pages. Bulk reuses published `rememberBulkAsync` only in relayer-processing mode and counts every item against the client's operation limit. Published bulk/analyze methods have no idempotency parameter; no invented key or uncertain retry is added. Returned job IDs preserve input order; status preserves done/failed/missing/pending independently, and waiting never cancels the original jobs. Forget removes index rows in the selected namespace while retaining encrypted blobs; restoration is a separate action with its own trust decision.

Published 0.1.6 exposes no public memories/agents/stats/forget methods. Its status wrappers also send a SEAL session by default even though metadata status does not require decryption. For these fixed routes, use the documented public REST signing protocol with the already pinned Sui `Ed25519Keypair.sign` API. Never invoke SDK private `signedRequest`, expose arbitrary paths, transmit raw delegate keys, or grant a SEAL session on metadata reads/index deletion. Every call retains fresh deployment/owner/active checks, SDK compatibility checks and the worker's existing origin/body/time bounds. Public owner metadata is explicitly owner-wide; it is not represented as namespace-restricted recall.

Memory metadata forwards only documented fields, deleted tombstones and `must_resync`. The Vela cursor binds the opaque remote cursor to the selected endpoint/network/package/account/owner. Continue based on `has_more`, including an empty page, preserve the last cursor for incremental polling, and discard incremental state when `must_resync` is true. A cursor hash is a scope guard, not authentication or a claim of complete recovered content. Network failures remain explicit and raw server diagnostics are not retained. These interfaces can be verified with the real signed protocol and synthetic loopback data without testnet gas; that is not real account/Blob persistence acceptance.

- 重写 Swift SEAL/Sui 协议会扩大密码学维护面；复用官方 SDK，后续通过公开底层 API 封装精确需要的能力。
- 默认后台远端同步会扩大数据边界，和用户明确 local-first 目标冲突；保持显式启用和操作。
- 直接在调用方线程执行官方 SDK 无法可靠隔离其日志/未暴露的 fetch timeout；选择独立 Worker 和协议限制。
- 默认信任服务端恢复可较快工作，但与端侧加密的承诺冲突；采取两个有明确名称、不同授权预览的数据路径。

## Verification / 验证

采用真实安装的官方 SDK、公开 SuiJsonRpcClient 和真实 Ed25519 签名；HTTP fixture 只代替远端服务，用新随机测试 key，不读个人账户。测试核对签名覆盖 path/body/nonce/account、分页、wrong owner/inactive、401/版本/响应上限/重定向、冻结参数、超时资源终止与未知副作用。包需要 npm pack 后在临时目录安装再测试。协议 fixture 和安装成功均不算真实加密远端持久化验收。

合成测试另覆盖三个真实官方 account builder 的 exact Move commands，以及新生成测试 key 对完整 bytes/gas cap/digest/owner 的签名验证；没有把它们发送到链上。[账户执行准备](../implementation/walrus-account-test-plan.md) 已给出实际字段与审批合同。

真实远端下一验收必须用用户明确选定的新测试账户、endpoint 和成本边界：合成原文写入 → 真实 durable job/blob 回执 → 全新 store 下载解密 → 摘要一致 → candidate 审核 → 召回；再验证撤销/轮换/完整恢复。任何未跑的步骤继续在审计里标记未验收。

## English summary

The optional adapter reuses pinned public official SDKs in a lazy isolated Worker. All remote recipients, account, namespace and network are explicit. Client encryption and relayer processing/restoration are separate trust paths. Exact reviewed actions are consumed once, unknown side effects are never retried, and unavailable pricing/duration are not fabricated. Protocol fixtures use the real SDK and signatures; they are not remote encrypted-storage acceptance. Full client-side recovery and desktop credential integration remain required follow-on work. Public owner transaction builders and exact signature verification are implemented; actual funded build/submission must still be accepted separately.

### Suppressed SDK diagnostics / SDK 吞错

已发布 Manual recall 在部分下载、初始化和解密失败后记录错误并返回空数组。隔离 Worker 只递增有界诊断计数，不格式化或保存任何原始日志参数；该请求返回 `partial` 和计数。无诊断仍只说明有界 SDK 结果，不建立账户全集证据。真实已安装 SDK 的坏密文 fixture 覆盖此行为。

### Client-side manifests and original records / 端侧清单与原始记忆

实现 `createMemoryManifest/validateMemoryManifest/restoreManifestPage`，复用公开 SealClient/SessionKey/EncryptedObject/Transaction API。恢复不用 relayer 或 embedding；链上账户及签署者、精确 namespace/owner/counter、包身份、认证解密、严格 UTF-8 与已知摘要分别核对。Manifest 有版本/未知字段/条数/大小/摘要边界，cursor 绑定摘要，每页有独立覆盖范围与逐项失败，不声称发现了整个账户全集。原有 MemWal 无预期明文摘要时允许显式 null，回执区分认证解密、核验预期摘要和新计算摘要。此实现仍需 funded testnet 的真实成功解密验收。

原始 UTF-8 与 Vela archive 是不同编码。Core `memory.archive.fromWalrusRecords` 只构造、校验候选归档，不联网、不写 Memory；显式非私有记录、内容 SHA、公开来源与可选 reader receipt。`/external/walrus/<source-hash>` 是虚拟 provenance，绝不读取该路径。来源与 receipt 保留为 caller-reported，Core 只证明本地内容哈希，不替调用者证明远端身份或 SEAL 认证。后续显式 import 继续用原子 createOnly 与候选审核。私有全备份与 active 状态恢复必须独立容器，不让 archive 切换状态或降低隐私。

单条 manifest 明文上限 1 MiB；本地原始 Memory 上限 512 KiB，较大的远端原始文本会明确拒绝 candidate 转换，需要用户明确拆分，不能静默截断。Manifest checksum 不是签名，SEAL 身份校验也不是 namespace ACL；delegate 仍是 account-wide。不改变默认 Mac runtime 或后台网络边界。
