# Model memory middleware contract / 模型记忆中间件合同

状态：`sdk/ai` 的本地 TypeScript AI SDK v4 已实现，安装后的 17 项真实宿主测试、12 项基础 SDK 兼容测试通过；Python Responses 同步/异步/流式已通过 30 项集成、12 项基础 SDK 兼容和 1 项旧 wheel 兼容；LangChain 与 reviewed remote analyze 尚待实现。精确证据见仓库 `sdk/ai/VERIFICATION.md`。架构决策见 [ADR 0026](../adr/0026-optional-model-memory-middleware.md)。本合同只规定非 UI 接口，不要求或代表客户端 UI 已完成。

## Fixed compatibility targets / 固定兼容基线

| Surface | Exact first acceptance target | Public mechanism |
| --- | --- | --- |
| TypeScript AI SDK | `ai 7.0.99`, `@ai-sdk/provider 4.0.14`, `@ai-sdk/openai 4.0.66` | `LanguageModelMiddleware` v4 / `wrapLanguageModel` / `generateText` / `streamText` |
| Python OpenAI | `openai 3.13.0`, Python >=3.10 | `OpenAI` / `AsyncOpenAI`, Responses `create`, public APIResponse and Stream lifecycle |
| Python LangChain | `langchain-core 1.6.3`, `langchain-openai 1.6.2` | public `Runnable` / message conversion / invoke, async and stream forwarding |

版本来源为第一方 [AI SDK registry](https://registry.npmjs.org/ai/7.0.99)、[provider registry](https://registry.npmjs.org/@ai-sdk/provider/4.0.14)、[OpenAI Python registry](https://pypi.org/pypi/openai/3.13.0/json)、[LangChain Core registry](https://pypi.org/pypi/langchain-core/1.6.3/json) 和 [LangChain OpenAI registry](https://pypi.org/pypi/langchain-openai/1.6.2/json)。AI SDK provider 发布包的 `src/language-model-middleware/v4/language-model-v4-middleware.ts` 实际定义 v4；不能沿用 MemWal 0.1.6 v2/v3 的 `any` 注释宣称兼容。版本、发布包摘要和已读取类型的来源会随首轮安装测试记录。

## Binding and call context / 固定绑定与单次上下文

公开 TypeScript 入口 `createVelaMemoryMiddleware(binding)` 返回 `{forTurn, close}`；`forTurn(context)` 返回 `{middleware, receipt, settled, close}`，供 `wrapLanguageModel` 使用，明确 session/turn 身份。不把 scope 或审批状态放进可被模型生成的 tool 参数。Python 已提供 `VelaResponses` / `AsyncVelaResponses`，以 `MemoryBinding` 和显式 `for_turn` 固定上下文。create 保留官方 Response，stream 逐项转发官方事件。LangChain 公共包装仍待下一切片，不修改原始模型对象。

当前 TypeScript binding：project/namespace/helperPath/storeHome/modelRecipient 与 `acknowledgeMemoryDisclosure: true` 必填，其余下表字段可选并有默认值。

| Field | Meaning and boundary |
| --- | --- |
| `project`, `namespace` | exact registered local project and namespace; caller selects, model cannot override |
| `helperPath`, `storeHome` | explicit local SDK configuration; discovery/watch/scheduler disabled |
| `modelRecipient` | frozen provider/model description; include exact origin where public API exposes it; no credentials |
| `retrieval` | lexical/semantic/hybrid, explicit language for embedding modes; limit 1..50, token budget and optional minimum similarity |
| `maxContextBytes` | final framed context bound, default 8 KiB, maximum 32 KiB; counts escaped UTF-8 bytes |
| `autoCapture` | default false; local only unless separate reviewed remote analysis configured |
| `filterText` | optional phase-aware callback `(phase, text, sourceMetadata) -> text | null`; no filesystem or credential scanning |
| `failurePolicy` | explicit `failClosed` default; optional `continueWithoutMemory` returns a degraded receipt, never silent success |

后续远端 memory binding 将作为显式 union 分支，当前包尚不接受此配置：使用被冻结的 Walrus profile 与 factory，由当前远端 SDK 管理凭据/Worker/预览；不从本地 binding 自动升级。该分支的 namespace 是组织分区，不是 delegate ACL。模型与 embedding/relayer 接收方分别列出，不能混成一个隐含云服务。

`MemoryTurn` 必填 `sessionID`、`turnID`；可选 caller abort/deadline。UTF-8 长度有界，不作为任意文件路径。source ID 是对这些标识、scope 和原始用户文本的摘要，不含原文。工具循环内相同 turn 保持相同 source ID；新用户输入必须新 turn，避免跨请求记忆和捕获状态混用。

## Before generation / 生成前

1. 验证固定绑定、实际可读 provider/model identity 和调用 deadline，建立单次 receipt。
2. 从最后一条 user/human 消息读取受支持 text parts；过滤查询文本，不提取 tool、assistant 或非文本附件。最后一条 user 无文字则跳过 recall/capture，有明确原因。
3. 调用限定 scope 的 SDK 召回；严格处理 unavailable、partial、index completeness。缺少 Memory 不是 0 条成功；按 failurePolicy 拒绝调用或明确降级。
4. 对已授权返回的 Memory 文本应用注入过滤，保留原 ID/source，不接受过滤器返回新 ID/scope。按最终 UTF-8 字节预算逐项容纳，记录过滤/截断数量。
5. 对不可闭合的固定标签 framing 和 HTML escape 后，附加到当前 user/human 的文字上下文。既有消息和部分内容保持顺序，原数组/对象不原地修改；system/developer 不提升权限。framing 标识是防反馈标记，不是内容可信证明。
6. 转发模型 options、tools、attachments、headers、provider options 及 abort。模型中间件只能证明传给宿主的内容；真实网络接收方的可验证程度单独返回。

自定义过滤器可删除/改写文本，不能绕过 scope/private 过滤、最终大小边界、转义、候选状态或接收方合同。返回非法类型、异常或超时按 failurePolicy 处理；不保留原始异常文本。不能用 regex 通过推断出“没有任何秘密”的保证。

## Completion, capture and receipts / 终态、捕获与回执

当前 TypeScript 公开 `MemoryReceipt` 包含：

```ts
type MemoryReceipt = {
  version: 1;
  turnID: string; modelCalls: number;
  scope: { project: string; namespace: string };
  modelRecipient: { provider: string; model: string; origin?: string; identityVerified: boolean; recipientVerified: false };
  recall: { state: 'pending' | 'used' | 'empty' | 'skipped' | 'degraded' | 'failed'; ids: string[];
    usedBytes: number; filteredCount: number; truncated: boolean; indexComplete: boolean | null };
  generation: 'pending' | 'finished' | 'failed' | 'cancelled' | 'incomplete';
  capture: { state: 'pending' | 'disabled' | 'skipped' | 'candidate' | 'failed' | 'uncertain';
    candidateIDs: string[]; effectsUnknown: boolean; integration: 'ai-sdk-v4'; reason?: string };
};
```

类型以安装包 `.d.ts` 为准；当前版本没有远端 jobs/analyze 字段，不将后续设计冒称已导出。Receipt 的普通日志不包含 prompt、记忆原文、模型输出、key、原始 provider error。`forTurn` 返回单次 `receipt()` 和可等待 `settled()`；`settled()` 必须在生成/流/capture 结束、失败或取消后完成，不留下永久 pending promise。每个 turn 只允许一个进行中模型调用；sequential reuse 的 `settled()` 代表最近已启动的模型调用，不代表整个 agent/tool workflow，必须先启动生成再等待。最多保留 32 个未关闭 turn。

成功终态后、本地 `autoCapture: true`：只保存本次原始用户文本的筛选结果，使用 `memory.integration.capture` 原子 create-only。candidate 不进入下一次召回，直到用户审核 active；记录不是 analyze 模型事实。模型返回空值/拒绝/错误/未知 finish 类型、流未读尽或中止时不自动保存。保留输出/工具/usage 原样，禁止为了提取事实额外发一次模型调用。

后续远端 analyze（当前未实现）需单独 `reviewAnalyze(preview)` callback。预览冻结原始用户文本、namespace、relayer/embedding recipients、operation ID 与预算；callback 明确返回同 preview 的批准结果才 execute，拒绝和取消无上传。callback 不得自行调用隐藏写方法绕开 receipt。返回 jobs 仅表示服务接受，durable 需后续 status。远端未知副作用禁止自动 retry。

流式封装保持背压，不聚合完整输出；观察公开 finish/error/abort 事件以定终态。显式 AbortSignal 或 turn.close 会取消并释放本次底层 reader；AI SDK 的下游 tee 提前停止/reader.cancel 可能不会取消 provider，调用方必须使用上述显式取消入口。任意自定义 provider 拒绝 cancel 时，释放等待限一秒，不宣称远端工作已终止。只关闭本包装器创建的 helper/stream，不关闭应用传入的模型 client。模型或网络端仍可能继续工作，receipt 不伪称已撤销费用或远端任务。

## Package acceptance matrix / 安装验收矩阵

TypeScript 当前 17 项真实宿主安装测试已通过；Python Responses 已单独完成安装验收；LangChain 和远端 analyze 各行仍待实现/验收。单独 optional-SDK job，不作为默认 Mac runtime 依赖。测试使用固定新 helper SHA、临时 stores/venv/Node consumer、合成模型凭据、loopback URL；不读取真实用户 home/config/key，不连接外部模型、Walrus 或 faucet。

| Scenario | Actual host path | Expected evidence |
| --- | --- | --- |
| Actual injection and preservation | AI SDK generateText, OpenAI Responses create; LangChain invoke pending | loopback request body contains same namespace active memory; tool schema/options/attachments/order unchanged |
| Streaming completion | AI SDK streamText, OpenAI Responses sync/async stream; LangChain stream/astream pending | original chunks/usage/finish remain available; bounded memory; candidate appears only after terminal consumption |
| Capturing disabled | every host, default configuration | Core has no new candidate, no remote callback/upload |
| Candidate and replay | successful nonstream/stream, repeated explicit turn ID | candidate-only original user text; deterministic ID, prior review retained |
| Failure/cancel/early close | actual provider error and partial SSE, client abort and iterator break | no auto capture; resources close; receipt settles, model outcome not retried by wrapper |
| Scope/private boundaries | two namespaces/agents/projects, malformed private fields | cross-scope/candidate/private absent from transmitted model input |
| Filters and framing | custom redaction/drop/throw/oversize + malicious tags | source remains fixed; no container breakout; bounds enforced; explicit degraded/failed receipt |
| Concurrent turns | same model across two independent bindings | no shared prompt/capture state, response receipts match turn |
| Unsupported/unknown shapes | typed fixture plus actual SDK validation | reject before provider dispatch; no coercion of arbitrary objects to prompt text |
| Remote analyze review | synthetic approved/rejected callback and signed loopback SDK | exact preview once, jobs accepted meaning, uncertainty and no automatic resend |
| Installed package | npm pack/temp consumer/tsc and wheel/temp venv imports | explicit package member allowlist, package/helper/version hashes, no source/tests/credentials shipped |

其他 SDK、OpenClaw、Walrus 的历史检查点不能代替本合同的宿主验收。本轮 TypeScript 安装收据与以前检查点分别保留。Python Chat Completions、Realtime、旧 AI SDK v2/v3、任意 LangChain 私有扩展或多模态内容理解需各自后续合同与实际运行测试，不能通过代理对象转发就宣称完成。用户要求的完整参考覆盖继续保留；此处只明确本次固定宿主实现顺序和精确验收边界。

## English summary

The local TypeScript AI SDK v4 package is implemented and has passed 17 real installed-host integration tests plus 12 base SDK compatibility tests; Python Responses adds 30 installed integration tests, 12 base SDK tests and one legacy-wheel test. LangChain and reviewed remote analyze remain planned. Each call binds explicit project/namespace and model recipients, preserves the original model request, injects bounded filtered references, and reports recall, generation and capture separately. Capture defaults off; successful local capture creates candidates only, while remote analysis requires an exact reviewed callback. Public framework methods, actual installed packages, synthetic loopback model requests, abort/resource behavior and scope-negative cases are required acceptance.

## Python Responses accepted boundary / Python Responses 已验收边界

精确公共接口和例子见 `sdk/python-ai/README.md`，源码固定 helper/包 SHA 见 `sdk/python-ai/VERIFICATION.md`。Python `for_turn` 返回 create、stream、receipt、settled、close；同步 stream 用 with，异步用 async with await。支持官方 Response.output 模型对象作为历史，使用其公开 to_dict 转换；不会把 assistant/tool 内容用于记忆查询。静态 `MemoryBinding` 与 SDK/Core 的严格能力列表在模型前校验；畸形 string/dict 不能当作支持声明。

同步取消不承诺 headers 前立即强制中断；采用 SDK timeout 和显式 Event/close，关闭已有响应但保留共享 client。等待结束与取消请求分开，以 settled 回执为准。异步 task cancellation 传播，完成生成后捕获期间被取消仍报告可能已提交的副作用。两者不增加模型或记忆重试。纯本地原文候选捕获不等于远端 analyze；本轮合成协议验收不等于模型质量或完整产品验收。

Python Responses 接收端冻结补充：每次调用在任何应用 filter 前创建公开 with_options 的 request client，只用该副本发送固定 model/base_url。应用仍拥有共享 HTTP transport，copy 不被 close；自定义网络转发/重定向不被冒称已认证。receipt.attempts 计入已接受的 wrapper 尝试，model_calls 只计 SDK dispatch，network_requests=null 表示不观测 SDK 内部重试/网络到达。capture 请求发出后收到畸形成功 ack 一律 uncertain，保留 effects_unknown，不自动重试。
