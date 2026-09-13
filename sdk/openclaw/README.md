# Vela memory for OpenClaw

Optional plugin for **OpenClaw 2026.9.4**, Node **>=24.16.0 <25 || >=26.1.0**. It uses the host's public plugin API. It adds no dependency to the Vela Mac application. Source packages are currently distributed by `npm pack`; they are not published to npm.

Install the packed `@vela-engineering/sdk` for the local backend, or `@vela-engineering/walrus` for the remote backend, alongside this plugin. Load the plugin directory using OpenClaw's `plugins.load.paths`, allow `vela-memory`, select `plugins.slots.memory: "vela-memory"`, and explicitly grant `plugins.entries.vela-memory.hooks.allowConversationAccess: true` and `allowPromptInjection: true`. Keep other memory providers out of the exclusive memory slot. Enable optional tools `memory_search` and `memory_store` through the host's tool policy.

Example **plugin config** (absolute paths must exist; register the project in Vela first):

```json
{
  "version": 1,
  "backend": "local",
  "helper": "/Applications/Vela.app/Contents/MacOS/vela",
  "home": "/absolute/selected/vela-store",
  "stateDirectory": "/absolute/plugin-state",
  "agents": {"main": {"project": "/absolute/project", "namespace": "main"}},
  "autoRecall": true,
  "autoCapture": false,
  "maxCaptureOperations": 100,
  "maxCaptureBytes": 1048576
}
```

`agentId` and workspace from the host select the mapping. Tool inputs cannot choose another agent, namespace or project. Unknown agents, a mismatched workspace or missing host identity fail closed. Namespace partitioning is not remote account ACL: MemWal delegates remain account-wide according to its protocol. The local helper is a process API with the operator's filesystem permissions, not an authenticated multi-user server.

`before_prompt_build` runs after tool policy, only when the host grants `memory_search`, and rechecks the capability after reading. Escaped historical references enter a bounded `<vela-memories>` frame marked as untrusted data. Private, inactive, other-project and other-namespace records never enter local recall. `maxRecallResults` defaults to 5, `maxContextBytes` to 8192. Remote `maxDistance` optionally filters the official SDK's distance directly; it is not a confidence percentage and is not supported by lexical local recall.

`memory_store` captures an explicit note. Optional `autoCapture` records the current prompt and selected new messages after a successful run; by default assistant text is excluded. Frames, credential-like text, filler and common injection patterns are filtered. These heuristics are not a proof of safe content. Tool-authored notes are attributed to the assistant. Locally, captured messages are **verbatim observations in candidate state**, requiring review before retrieval; no model is called. To perform the official MemWal fact extraction remotely, select `backend: "walrus"`, a strict `remote.profile` in `relayerProcessing` mode, explicit credentials and `remotePlaintextAcknowledged: true`. This sends selected plaintext to the named relayer using its published `analyze` API. Accepted job IDs are not durable-write receipts. This mode does not promise client-only encryption or client-side extraction.

The remote profile/credentials follow the separate Walrus SDK contract. No credentials are discovered from existing wallets or environment files. In unattended capture the configured consent, namespace and durable byte/operation caps authorize the bounded remote operation; exact arguments are frozen in a single-use SDK action before dispatch. Analyze has no published idempotency key. A local SQLite journal commits a hash-only claim before dispatch, retains accepted/failed/uncertain states across restarts and never automatically resubmits a claimed operation. Limits count attempted operations, including uncertain ones. Journal identity binds backend, project, namespace and the full public remote profile; displayed budget usage includes all attempts in the configured journal. The journal contains no conversation text or keys. Inspect uncertain jobs before any deliberate new request. There is no background restore or automatic trust upgrade.

```sh
openclaw vela-memory search "SQLite" --agent main --limit 5
openclaw vela-memory stats --agent main
```

Statistics report observed local state, or the remote namespace response and its pagination boundary. They do not invent a complete account inventory. Gateway stop closes owned child processes/workers. Canceling transport may leave an already submitted remote write in an unknown state.

## 中文说明

这是独立可选 OpenClaw 插件，不增加 macOS 客户端运行时。宿主确认的 agent 和 workspace 决定 project/namespace，模型的工具参数不能切换作用域。默认召回开启、自动捕获关闭；本地捕获只产生待审核的原文观察，不冒充模型提炼。远端事实提炼需显式接受 relayer 接收明文，使用官方 SDK 的 analyze 并返回异步任务凭证。命名空间不是远端权限隔离。

持久操作日志在写入前提交，避免超时、崩溃或重启后重复提交未知副作用。召回过滤 Private Library、候选状态、其他项目和命名空间，注入框明确标记不可信历史资料。验证包括真实隔离 OpenClaw 宿主的插件加载、CLI 与 hook runner，以及实际 Vela helper；此外实际运行完整宿主 turn，通过本机合成 provider 验证实际 prompt、memory_store 工具调用和 agent_end 捕获；这不证明真实模型语义质量或远端加密写入成功。具体证据见仓库 `docs/parity/walrus-memory.md`。

`captureMaxMessages` counts every selected message, including the current user input. When the cap is 1, no additional assistant/history message is captured. 中文：捕获条数上限包含当前用户输入；设为 1 时不会额外保存助手或历史消息。
