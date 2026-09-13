# Vela memory for Python Responses

Optional memory composition for **OpenAI Python 3.13.0**, Python 3.10+, and an explicitly selected local Vela helper. It uses the official synchronous/async Responses API and streamed event types. It is not part of the default Mac runtime, does not choose a model or create an account, and has not been published to PyPI.

Build wheels for `sdk/python` and `sdk/python-ai`, then install both wheels in your application. The latter requires the pinned OpenAI SDK; the base Vela SDK remains free of third-party runtime dependencies. No source/tests/internal evidence or real credentials ship in either wheel.

```python
from vela_ai import MemoryBinding, VelaResponses

# client is your existing, explicitly configured OpenAI client.
# model_id is the model you selected for this application.
binding = MemoryBinding(
    project="/absolute/registered/project", namespace="researcher",
    helper_path="/absolute/path/to/vela", store_home="/absolute/path/to/store",
    model=model_id, base_url=str(client.base_url),
    acknowledge_memory_disclosure=True,
    auto_capture=False,
)
with VelaResponses(client, binding) as memory:
    with memory.for_turn(session_id="session-1", turn_id="input-1") as turn:
        response = turn.create(
            input="What did we decide about project persistence?",
            instructions="Your existing application instructions.",
            store=False,  # Explicit application choice, forwarded unchanged.
        )
        receipt = turn.settled()
```

The wrapper never closes the application client. Its `model` and public `base_url` configuration must match the frozen binding before each request. Receipts distinguish this configuration check from actual network identity authentication, which is not established. Custom transports, provider credentials and model retry settings remain the application's responsibility; verification sets retries to zero. Requests retain the application's `store`, conversation/history, instructions, tools, file/image inputs, headers and other supported SDK options. OpenAI's own storage policy applies to model requests; local Vela storage does not override it. `extra_body` cannot override protected input/model/stream/background fields.

Only the last user text forms a memory query. String input, message dictionaries and official OpenAI model objects returned in `Response.output` are supported; official objects are normalized through their public `to_dict` method. Tool/assistant content and non-text attachments are not queried or captured. Existing history, messages and input objects are not modified. Empty user text skips retrieval/capture and preserves the model request. Active, non-private exact-project/namespace memories are checked again and appended in an escaped, bounded untrusted reference frame. Current recall is lexical; other Vela semantic interfaces remain separate SDK capabilities.

`filter_text(phase, text, metadata)` may remove/redact query, injection or capture text by returning text or None. Sync clients require synchronous callbacks; async clients also await async callbacks. Filters do not sanitize the application's original model prompt or tool arguments. Built-in credential-pattern filtering and reference framing are safeguards, not proof of secret absence or model obedience. `failure_policy="continueWithoutMemory"` opts into explicit degraded recall after a memory/filter error; scope/recipient mismatch always fails closed.

Capture defaults off. `auto_capture=True` checks exact SDK/Core `openai-responses` support before provider dispatch. Successful terminal output may then save **only the filtered original user input as a candidate observation**. No model output is captured, no facts are extracted by a second model call, and candidates remain unavailable to retrieval until reviewed active. Session/turn/input hashes provide replay identity; repeated capture preserves a later human review. Missing, failed, incomplete, empty or refused responses never auto-capture.

`receipt()` provides a copied snapshot; `settled()` must be called after starting a model operation, consuming a stream or closing the turn. It reports the latest model call, not an entire tool workflow. Model success and capture failure/uncertainty are separate. A lost acknowledgement may follow a real committed write: inspect `capture.effects_unknown` and the selected store before recovery, and do not automatically retry. No wrapper retry is added.

```python
# Synchronous stream ownership: EOF is required before candidate capture.
# Run this inside the VelaResponses context above.
with memory.for_turn(session_id="session-1", turn_id="input-2") as turn:
    with turn.stream(input="Explain the selected storage policy.", store=False) as stream:
        for event in stream:
            if event.type == "response.output_text.delta":
                print(event.delta, end="")
    receipt = turn.settled()
```

Use `AsyncVelaResponses` with a caller-owned `AsyncOpenAI` client for async methods:

```python
from vela_ai import AsyncVelaResponses

async with AsyncVelaResponses(async_client, binding) as memory:
    async with memory.for_turn(session_id="session-1", turn_id="input-3") as turn:
        async with await turn.stream(input="Explain project persistence.", store=False) as stream:
            async for event in stream:
                if event.type == "response.output_text.delta":
                    print(event.delta, end="")
        receipt = await turn.settled()
```

Stream wrappers forward official events without collecting the model output. Auto-capture requires the completed response event and EOF; early stream context exit/close creates no candidate. Merely abandoning an iterator is not proof that it was closed. Each turn allows one in-flight operation, with independent turns for concurrency; the manager holds at most 32 unclosed turns.

Sync callers may pass a `threading.Event` as `cancel_event`, or call `turn.close()`. Cancellation is checked at each SDK/stream boundary and closes an acquired response/helper. Before headers, the synchronous SDK has no public per-request forced abort handle; the wait is limited by its per-attempt request timeout and the application's retry policy. `close()` can return before that in-flight call settles; use `settled(timeout=...)` when you need its final receipt. It never closes the shared model client to simulate per-request cancellation. Async callers use task cancellation or `await turn.close()`; cancellation propagates while owned responses/helpers are released. Cancellation during a committed capture preserves its possible effects, even when the caller receives `CancelledError`. Neither path claims server work, billing or writes were rolled back. Application callbacks must release resources and cooperate with cancellation.

Defaults: 15-second helper/model request timeout, 120-second turn deadline, 5 memory results, 2,000-token retrieval budget, 8 KiB framed context. Configurable limits: 120 seconds, 50 results, 4,000 tokens, 32 KiB context. Input serialization is bounded to 2 MiB and selected text to 16 KiB; model response parsing follows the official SDK. A streaming async close waits at most one second for a custom response implementation; it cannot prove an uncooperative transport stopped remote work.

Run `python3 scripts/test-python-ai-integrations.py` from the repository to install both wheels into a disposable consumer and exercise the pinned real SDK, loopback HTTP/SSE and a real helper. `VELA_PYTHON_AI_HELPER` selects a helper built from an explicit source snapshot. `VELA_PYTHON_AI_LEGACY_SDK` optionally selects a retained older base SDK wheel for separate installed compatibility verification. Detailed version/package/helper evidence is retained separately in the repository, not in runtime wheels. This verifies integration behavior, not external model quality, LangChain, remote analyze or full Walrus parity.

## 简体中文

这是独立安装的 Python Responses 接入，支持同步、异步和官方流式事件。必须明确项目、namespace、helper/store、模型与接收端配置，并确认记忆会交给该模型；配置核对不代表网络身份已经认证。默认只召回同 namespace 的 active 非私有记忆，不改变原始指令、历史、工具和附件。

显式开启捕获后，只在完整成功终态把原始用户文本保存为 `openai-responses` 候选，不保存模型输出，不自动激活。已提交但响应丢失会明确报告未知副作用，生成结果与捕获状态分别记录，不重发。过滤只处理记忆文本，不替应用全部 prompt 做全面脱敏。

流必须用上下文管理器消费或显式关闭。同步取消在 SDK 边界检查；未收到 headers 前只能由官方 SDK 超时及调用者重试策略限制等待，不以关闭共享 client 假装单次强制取消。异步使用 task cancellation 或 await close，并保留真实写入的未知影响。结束后查看 settled 回执；单次 turn 不等于整个 agent 工作流。

仅覆盖已明确测试的 Python Responses 入口；Chat Completions、LangChain、远端 analyze 和真实模型质量仍需后续实现与独立验收。本包不进入默认 Mac 依赖，也不代表三个参考产品已全部验收。
