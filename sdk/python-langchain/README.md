# Vela memory for LangChain

Explicit local memory for **LangChain Core 1.6.3**, with an optional **ChatOpenAI 1.6.2 / OpenAI 3.13.0** adapter. It composes with the public Runnable API and requires no Python runtime in the default Mac app. This package has not been published to PyPI.

Build the `sdk/python` and `sdk/python-langchain` wheels and install both. Install the latter wheel with `[openai]` for the supported provider adapter. The base package can be imported without OpenAI/provider packages; it does not discover credentials, select a model, or start a helper until a memory operation begins. The caller supplies the already configured model, an absolute helper/store, and a registered project.

```python
from vela_langchain import MemoryBinding, VelaLangChain
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser

# model is your configured ChatOpenAI instance, using Chat Completions.
# Every configured root client must use the same explicit base URL.
binding = MemoryBinding(
    project="/absolute/registered/project", namespace="researcher",
    helper_path="/absolute/path/to/vela", store_home="/absolute/store",
    model=model.model_name, base_url=str(model.root_client.base_url),
    acknowledge_memory_disclosure=True, auto_capture=False,
)
with VelaLangChain(model, binding) as memory:
    with memory.for_turn(session_id="session-1", turn_id="input-1") as turn:
        chain = ChatPromptTemplate.from_messages([
            ("system", "Your existing application instructions."),
            ("human", "{question}"),
        ]) | turn | StrOutputParser()
        answer = chain.invoke({"question": "What did we decide about SQLite?"})
        receipt = turn.settled()
```

The adapter accepts the exact official `ChatOpenAI` class and ordinary public `RunnableBinding` data returned by `bind_tools`, `bind` and `with_config`. It snapshots the model's public settings, JSON tool arguments and request options **before memory callbacks**. Request-specific official client copies fix every configured base URL, model, default headers/query and timeout; public `model_copy` constructs the model that actually runs. A filter changing the original model's URLs, name or bound tool dictionaries cannot redirect this request. The snapshot shares the application's HTTP transports, so the wrapper closes only its own response/stream/helper; it never closes the model or its client copies. The actual public root defaults must match the ChatOpenAI header/query configuration; a distinct root override is rejected rather than silently dropped. Dynamic API-key providers remain callable at request time. Async-only credentials use the async entry points; the adapter does not invent a synchronous client. It cannot authenticate DNS, redirects or custom transport behavior.

Supported entry points are `invoke`, `ainvoke`, `stream` and `astream`, either directly or between a public prompt and output parser in LCEL. Model output remains the original `AIMessage`/`AIMessageChunk`. Only one in-flight call is allowed per explicit turn; use distinct turns for concurrent inputs. Single-turn `batch`/`abatch` and completion-order variants reject before dispatch rather than partially executing a batch. One manager supports one active async event loop. Custom ChatModel subclasses, opaque/dynamic routing graphs, configuration factories, configurable alternatives and Responses routing require separate adapters and are currently rejected. This does not claim all LangChain providers or graph types are supported.

Only the last `HumanMessage` text forms the query; mixed string/dictionary text blocks retain their original order. Public `PromptValue`, strings and supported message forms are copied; system/assistant/tool roles and image/file content are preserved without being queried or promoted to instruction authority. Only active, non-private memories matching the exact registered project and namespace are injected. References are escaped and bounded, attached to the current human message as untrusted historical data. This integration currently uses lexical recall. Candidate, private, global/project-only and other namespace records do not enter it.

`filter_text(phase, text, metadata)` handles `query`, `injection` and `capture`; return text or `None`. Async operations can await filters. The filter applies to memory processing, not the entire application prompt. `failure_policy="continueWithoutMemory"` explicitly permits degraded retrieval; invalid scope, unsupported capture capability and recipient violations still fail closed. This is a local SDK boundary, not external account/namespace authentication.

Capture defaults off. With `auto_capture=True`, the helper and SDK must explicitly support `langchain`. Only non-empty text with `finish_reason="stop"`, no tool/refusal/error and, for streams, a complete EOF may capture **the filtered original user input as a candidate**. The wrapper does not store model output, call an extraction model or automatically activate memory. Project/namespace/session/turn/input hashes provide replay identity, and replay preserves later human review. Unsupported termination metadata skips capture.

```python
from contextlib import closing, aclosing

# Inside the manager context, with a new explicit turn:
with memory.for_turn(session_id="session-1", turn_id="input-2") as turn:
    with closing(turn.stream("Explain the storage decision.")) as stream:
        for chunk in stream:
            print(chunk.text, end="")
    receipt = turn.settled()

# In asynchronous application code:
async with VelaLangChain(model, binding) as memory:
    async with memory.for_turn(session_id="session-1", turn_id="input-3") as turn:
        async with aclosing(turn.astream("Explain the storage decision.")) as stream:
            async for chunk in stream:
                print(chunk.text, end="")
        receipt = await turn.asettled()
```

Streams must be consumed or explicitly closed; dropping an iterator or breaking a loop alone does not establish cleanup. Async task cancellation propagates and releases owned resources. `close()` signals cancellation; `aclose()` waits for async cleanup, and `settled`/`asettled` returns the final receipt. Synchronous in-flight HTTP cannot be forcibly interrupted through a public per-request ChatOpenAI method before headers: timeout and the caller's retry settings bound that wait. Closing this wrapper never closes shared transports or claims server work was cancelled or a write rolled back. Application callbacks/rate limiters must cooperate with cancellation; application tracing and custom transports remain application-owned.

Receipt fields distinguish `attempts`, `model_calls` (LangChain method dispatches), and `network_requests=None` (network delivery, cache hits and SDK retries are not observed). Generation and capture are separate. A lost or semantically invalid acknowledgement after capture may follow a committed write and reports `capture.state="uncertain"`, `effects_unknown=True`. Inspect the selected store before recovery; no automatic mutation retry is added. Receipts are copied and do not contain raw prompts or provider diagnostic bodies.

Defaults: 15-second helper/request timeout, 120-second turn deadline, 5 results, 2,000-token retrieval budget, 8 KiB framed references. Limits: 50 results, 4,000 tokens, 32 KiB context, 2 MiB serialized message/options and 16 KiB selected text. The wrapper does not collect stream text; upstream LangChain/provider implementations may retain chunks internally. Callback, cache and tracing configuration remain the application's responsibility.

Run `python3 scripts/test-langchain-integrations.py` with an explicit source-frozen helper selected by `VELA_LANGCHAIN_HELPER` and optional `VELA_LANGCHAIN_SOURCE_MANIFEST`. `VELA_LANGCHAIN_LEGACY_SDK` selects a retained pre-LangChain wheel for actual installed compatibility. The runner creates disposable consumers, tests the base import without provider dependencies, installs the pinned extra, and drives real ChatOpenAI HTTP/SSE plus the real helper against synthetic stores. It does not use external models, accounts, remote memory, wallets or billing.

## 简体中文

这是独立安装的 LangChain 接入，默认 Mac 软件不增加 Python 依赖。基础包只有 LangChain Core 与本地 Vela SDK；明确安装 `openai` extra 后启用固定版本的 ChatOpenAI 适配器。支持直接或 LCEL 中的同步、异步、流式调用，并保留原始消息角色、工具和附件。

每次调用先冻结公开模型设置、已配置 client 的接收地址、默认头/查询参数和绑定工具，再执行记忆 filter；原模型之后改址不会改变该请求。只召回当前项目和 namespace 的 active 非私有记忆。捕获默认关闭，显式开启后也只在成功终态和 EOF 后保存原用户文本为 `langchain` 候选，不自动激活、不保存模型输出。

取消、流关闭、预检零提交、不同 namespace 并发、已提交但回执损坏的未知影响均独立验收。未知影响不能解释为零写入，也不会自动重试。单 turn 批量、动态路由、其它 provider 与真实模型质量尚未验收，不以这些本地结果冒称三个参考产品已全部完成。
