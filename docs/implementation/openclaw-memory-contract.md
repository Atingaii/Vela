# OpenClaw memory contract / 插件与候选记忆合同

Backend and public process API: [ADR 0023](../adr/0023-scoped-openclaw-memory-integration.md). Package install/configuration: [plugin README](../../sdk/openclaw/README.md).

## Core API

All three methods require an explicitly registered canonical `project` and a non-empty `namespace` (max 256 UTF-8 bytes, no control characters). Unknown fields are rejected. This process API does not authenticate an OpenClaw host or make an account-wide delegate into a namespace ACL.

`memory.integration.capture`:

```json
{"project":"/registered/project","namespace":"researcher","integration":"openclaw","sourceID":"run-hash","records":[{"id":"message-id","role":"user","content":"Original selected message"}]}
```

1–20 records, 16 KiB per message, 64 KiB request. Optional title max 300 characters. Roles are user/assistant; credential-like content is rejected. Return: `created`, `skipped`, `ids`, `skippedIds`, `namespace`, `state: "candidate"`, `modelCalled: false`, `method: "verbatim-selected-messages"`, `hostAuthenticatedByCore: false`. Each identity binds project/namespace/source/message/role/content hash. Writes are atomic/create-only. Repeating identical input does not replace a later human review. No source file is opened and no model is called.

`memory.integration.recall`: `project`, `namespace`, `query`, optional `budget`, `limit` (integer 1–50; default 5), `retrievalMode` (lexical/default, semantic, hybrid), `language`, `minSimilarity`. Same project + exact namespace + active + non-private eligibility applies before scoring; ordinary recall excludes namespace scope. Semantic index is explicit and source hashes include namespace. Existing recall result fields retain their meaning; lexical relevance is not cosine or confidence.

`memory.integration.stats`: `project`, `namespace`. Returns actual `observedRecords`, grouped `states`, `limit: 10000`, `complete` and `namespaceIsRemoteACL: false`. Hitting the scan limit reports incomplete. This is not a total remote account inventory or billing estimate.

## Desktop presentation boundary

Namespace memories are ordinary stored `memory` records with `scope: "namespace"`, a visible namespace value and candidate state. Review can show original message, integration/source identity, and `provenance.method`; label them as captured observations, not verified facts. Existing `memory.transition` controls activation. Do not auto-activate captured records. Do not hide the namespace when displaying or editing scope, or silently make them project-global. An archive imported into a chosen project retains the source namespace as provenance and requires review there.

No UI implementation is part of this module. UI work remains assigned to Antigravity Gemini 3.8 Flash (High).

## Host behavior

Explicit configured agent mapping and a matching trusted workspace select scope. Tool arguments expose only query/limit or text. The post-policy hook requires `memory_search` to inject and `memory_store` to establish an optional capture baseline; the latter can work when automatic recall is disabled. The capture baseline is run/session-bound and consumes after agent_end. Missing baseline, failed runs, unknown agents or mismatched workspace do not capture. Assistant capture defaults off. Ordinary operators may use `openclaw vela-memory search/stats --agent <configured-id>`.

Remote `analyze` is available only with explicit relayer-processing plaintext consent. It uses official short-lived SEAL session credentials and signed requests. The plugin journal stores hashes, byte counts and safe receipt IDs before/after dispatch; no plaintext or credentials. An accepted remote job is not called durable. Unknown effects never auto-retry. Keychain-backed desktop configuration, actual model turns, NemoClaw deployment and funded encrypted remote writes/restores require separate acceptance.

## Verification boundary

`scripts/test-openclaw.py` installs packed packages into a disposable consumer, type-checks against the pinned host, configures only temporary `OPENCLAW_STATE_DIR`/`OPENCLAW_CONFIG_PATH`, and runs actual host plugin loading and CLI commands. It invokes the real host hook runner (test-only pinned implementation export) with an isolated real helper for source/scope/capture assertions. It also runs an actual embedded OpenClaw turn against a synthetic loopback OpenAI-compatible endpoint, verifies emitted namespace context, executes memory_store through the real host, and checks agent_end capture. It does not launch an external model, daemon or remote memory request. Standard npm installation requires network; test calls are local.

中文：本轮证明实际宿主加载、命令、hook 权限与 helper 数据闭环，本机合成 provider 已收到实际宿主 prompt 并返回工具调用；不能据此宣称真实模型理解和使用了注入内容、NemoClaw 已全面兼容，或远端加密存储/恢复已经成功。完整功能目标保持不变，未验收条目仍需继续执行。
