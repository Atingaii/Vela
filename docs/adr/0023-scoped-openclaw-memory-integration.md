# ADR 0023: Scoped OpenClaw memory integration

Status: accepted (2026-09-13)

## Decision

Ship `sdk/openclaw` as an optional plugin for the pinned public **OpenClaw 2026.9.4** API, requiring Node **>=24.16.0 <25 || >=26.1.0**. The manifest declares static tool ownership and replay/side-effect metadata; without those declarations the 2026.9.4 lazy loader does not activate tools on a real agent turn. It is installed separately from the Mac app, with the local SDK or optional Walrus SDK. This avoids bundling a large agent runtime merely to observe and support agent sessions. Plugin behavior is tested using an isolated real host, not copied reference plugin code.

The operator maps each known host agent to an explicit registered Vela project and namespace. Runtime agent identity, session identity and workspace determine selection; tool arguments cannot override them. Unknown agents, conflicting session/agent identities and mismatched workspaces fail closed. `memory.integration.capture/recall/stats` form a narrow local process API. They do not establish a remote identity or ACL. An external caller with direct helper access retains the operator's local permissions. Walrus delegates remain account-wide per the official protocol; namespaces partition organization, not cryptographic authority.

Memory gains a `namespace` scope. Ordinary project recall excludes it. Integration recall requires exact namespace, the same project, active state and strict non-private eligibility. The semantic source hash includes namespace only for this new scope; changing it invalidates an existing embedding. Existing project-scope embedding hashes remain compatible. Archives preserve namespace as source provenance; candidate import still requires an explicit target project and does not silently activate a remote scope.

The prompt hook requests post-policy tool authority. Automatic recall requires `memory_search`, and automatic capture also requires `memory_store` in that run's finalized tool surface. Recall checks active authority after the awaited read. The plugin returns escaped, byte-bounded, explicitly untrusted reference text. It strips its own and MemWal reference frames and filters common injection/credential patterns during capture; these are defense-in-depth heuristics, not guarantees of model obedience.

Capture is opt-in. Local capture saves selected original messages as **candidate observations**, with source identity and content hash, without claiming model extraction. The current prompt counts toward the same message cap as eligible new messages; the cap is checked before appending, including at its minimum value of one. Assistant messages are excluded by default, and captured candidates cannot immediately create a feedback loop. Candidate import is atomic/create-only; content and identity are deterministic, replay preserves any later review state. Core records `hostAuthenticatedByCore: false` because the local API does not attest the external host.

The remote mode uses the published MemWal `analyze` API only in `relayerProcessing` mode with explicit plaintext-recipient consent. Its returned fact/job IDs are accepted jobs, not durable storage receipts. Analyze has no published idempotency key. An independent SQLite journal commits a hash-only claim before dispatch and counts attempted operations/bytes across restarts; accepted, failed and uncertain claims are never retried automatically. Exact arguments are frozen in a single-use Walrus SDK action, within the configured unattended-capture consent and caps. No restore or trust upgrade runs in the background.

`node:sqlite` supplies the journal without another npm dependency. Database permissions are 0600; no raw conversation, credentials or model output is journaled. Request errors log only a bounded known error code. Each operation closes its own helper/worker; gateway stop cancels owned resources. Transport cancellation does not imply that an accepted remote operation was canceled.

## Alternatives and consequences

Using a global namespace by default is simpler but risks silent cross-agent retrieval; rejected. Treating local capture as automatic active fact extraction is misleading and feeds unreviewed output back into prompts; rejected. A separate local authenticated multi-user memory service would add deployment, credentials and ACL policy without being necessary for a trusted desktop process integration; deferred until the corresponding remote/provider boundary is designed, not substituted with a fictional local ACL.

The real OpenClaw host and hook runner validate loading, command dispatch and post-policy hook behavior. A complete embedded agent turn against a synthetic loopback provider further verifies the actual emitted prompt, memory_store execution/result round-trip, and agent_end capture. This full turn found and fixed a missing manifest tool-ownership declaration that isolated hook tests could not reveal. The pinned internal hook-runner export is a **test-only** fixture; production imports only public host types/API. The synthetic provider verifies transport receipt of the final prompt. These tests do not establish real model comprehension or semantic quality, that every NemoClaw environment has the same API, or that funded Walrus encrypted storage/restore has completed. Those acceptance items remain explicit in the parity matrix.

## 中文摘要

插件独立安装，不增加 Mac 客户端运行时；宿主 agent/workspace 选择明确 project/namespace，工具参数不能跨域。命名空间进入真实 Core/语义过滤，Private Library 与候选记忆不参与召回。自动捕获默认关闭且受宿主 memory_store 权限约束，本地只生成候选原文观察；远端调用官方 analyze 必须明示 relayer 接收明文。SQLite 日志在写入前持久占用额度，未知结果不自动重发。真实 OpenClaw 加载、CLI 与 hook runner 是宿主接入验证，不冒称真实模型或远端加密回环验收。

## Sources

- [OpenClaw v2026.9.4 public plugin types](https://github.com/openclaw/openclaw/tree/v2026.9.4/src/plugins)
- [OpenClaw conversation and prompt hooks](https://docs.openclaw.ai/plugins/hooks/prompt-and-session)
- [OpenClaw plugin manifest](https://docs.openclaw.ai/plugins/manifest)
- [MemWal pinned OpenClaw reference](https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/openclaw/reference.md)
- [MemWal published TypeScript SDK 0.1.6](https://www.npmjs.com/package/@mysten-incubation/memwal/v/0.1.6)
