# Vela memory for AI SDK

Optional TypeScript middleware for **AI SDK 7.0.99 / provider interface v4**, Node.js 22+. Uses the separately installed local Vela SDK and explicit macOS helper. It is not a model provider, agent framework, or part of the default Mac runtime. This development package has not been published to npm.

Build from the repository with `npm ci --ignore-scripts && npm run build` after running `npm ci --ignore-scripts && npm run build` in `sdk/typescript`. Pack both packages and install their `.tgz` files alongside `ai@7.0.99`. The local development link is only a dev dependency; installed consumers use the separately packed SDK peer.

```ts
import {generateText, wrapLanguageModel} from 'ai';
import {createVelaMemoryMiddleware} from '@vela-engineering/ai';

// model is an existing AI SDK v4 model configured by your application.
const memory = createVelaMemoryMiddleware({
  project: '/absolute/registered/project', namespace: 'researcher',
  helperPath: '/absolute/path/to/vela', storeHome: '/absolute/path/to/store',
  modelRecipient: {provider: model.provider, model: model.modelId},
  acknowledgeMemoryDisclosure: true,
  retrieval: {retrievalMode: 'lexical', limit: 5, budget: 2000},
  autoCapture: false,
});
const turn = memory.forTurn({sessionID: 'application-session', turnID: 'user-turn-1'});
try {
  const result = await generateText({
    model: wrapLanguageModel({model, middleware: turn.middleware}),
    prompt: 'What did we decide about the database?', maxRetries: 0,
  });
  const receipt = await turn.settled();
} finally {
  await turn.close();
  await memory.close();
}
```

The binding fixes the registered project, exact namespace, model provider/model ID and disclosure acknowledgement. An optional `modelRecipient.origin` is a caller declaration: middleware cannot inspect an arbitrary model's network transport. Receipts distinguish checked model identity from unverified network origin. Provider credentials stay in the application's model object; this package does not scan environment or credential files, choose an external model, or make requests directly to one.

Only the last user message's text parts form the memory query. Active non-private memories in that same project/namespace are checked again before use. Bounded, escaped references are appended as text to that user message; existing instructions/system messages, attachments, tools, provider options and message order are preserved. Reference text is untrusted data. Framing and filters do not prove model obedience or absence of every secret.

`filterText(phase, text, source)` can remove or redact memory query, injection and capture text; return a string or null. Filters cannot change memory IDs/scope or bypass final limits and framing. They do **not** redact the application's existing model prompt or tools. Async filter waits are bounded by the turn's timeout/abort; application callbacks must manage any resources they create. Helper/provider diagnostics are never retained in a receipt. `failurePolicy` defaults to `failClosed`; explicitly choose `continueWithoutMemory` to continue after a memory/filter error with a degraded receipt. Scope or recipient mismatch always fails closed.

Capture defaults off. Set `autoCapture: true` only to save the successful model call's original user text as a **candidate observation**, never an active fact or model-derived claim. It uses the explicit `ai-sdk-v4` integration identity; the current SDK and Core must advertise support, otherwise generation fails before provider dispatch with no capture. AI SDK v4 support is detected before each call using the scoped Core statistics response. Older OpenClaw-only capture interfaces are never silently reused.

Capture occurs after a non-empty `stop` result or a fully consumed provider stream with a `stop` finish. Model failure, refusal, truncation, empty output, abort and incomplete stream do not automatically capture. Capture errors preserve the successful model response and report failed/uncertain state separately; inspect `effectsUnknown` before deciding recovery. Session ID, turn ID and original text hash determine replay identity. Keep the same turn ID for the same input/retry; use a new turn ID for a new user input. Repeated capture is create-only and preserves later human review.

Each turn allows one model call at a time; use separate turns for concurrency. Sequential calls can reuse a turn; `settled()` describes its latest started model call, not the entire agent/tool workflow. Always start/consume the model operation before awaiting it. Streaming chunks pass through without accumulating model output. Cancel the provided `AbortSignal` or call `turn.close()` to stop the owned provider stream; stopping a downstream AI SDK tee/iterator alone might not cancel the provider. Close terminates owned helpers and cancels/releases the owned stream reader (with a one-second bound for a custom stream that ignores cancellation), not the caller's model client, and does not claim provider billing or Core writes rolled back. The middleware adds no retries; configure the AI SDK's own retry policy explicitly.

The manager retains at most 32 unclosed turn handles. Close turns when done. `maxContextBytes` defaults to 8 KiB, maximum 32 KiB; retrieval limit is 1–50 and memory token budget 0–4,000. Memory helper timeout defaults to 15 seconds; turn/model/filter timeout defaults to 120 seconds, maximum 120 seconds. Current support is local memory with explicit model disclosure. Reviewed remote analyze and Python wrappers remain separate work; no callback shell is counted as remote integration.

Run `python3 scripts/test-ai-integrations.py` from the repository for installed-package verification against the pinned real AI SDK, a loopback HTTP/SSE provider, and a frozen real helper. This checks transport and memory behavior, not external model quality. The repository files `sdk/ai/VERIFICATION.md` and `sdk/ai/INTEGRATION-NOTES.md` record exact evidence and shared-interface changes; they are deliberately not shipped in the runtime package. Set `VELA_AI_LEGACY_SDK_PACKAGE` to a retained pre-AI local SDK tarball to run the additional installed legacy compatibility acceptance.

## 简体中文

这是独立安装的 AI SDK v4 记忆中间件，不进入默认 Mac 安装包。必须显式选择项目、namespace、模型身份并确认记忆会交给该模型；网络地址若只由调用者提供，回执不会冒称已验证。默认只读取同 namespace 的 active、非私有记忆，并以受限、不可信引用文字附在用户消息中。

可扩展文本过滤只作用于记忆查询/注入/捕获，不替应用原始 prompt 或工具做全面脱敏。自动捕获默认关闭；开启后仅在模型成功终态保存原始用户文本 candidate，不提取模型事实，不自动激活，不把 AI SDK 来源标成 OpenClaw。旧 SDK/Core 缺乏独立标识时明确拒绝，零写入。生成和捕获回执分开，未知副作用不能自动重发。

每个 turn 只允许一个进行中调用，不同 turn 可并发。调用后读取 `settled()`，结束后显式 `close()`；流式取消使用 AbortSignal 或 turn.close，不能把停止某个下游 tee 消费者等同于网络提供方已取消。真实模型质量、远端 analyze 与 Python wrapper 不在本包的当前验收声明内。
