# Model memory middleware contract / 模型记忆中间件合同

状态：下一阶段拟实现公共合同，**尚无 `sdk/ai` 或 `sdk/python-ai` 实现与测试通过声明**。架构决策见 [ADR 0026](../adr/0026-optional-model-memory-middleware.md)。本合同只规定非 UI 接口，不要求或代表客户端 UI 已完成。

## Fixed compatibility targets / 固定兼容基线

| Surface | Exact first acceptance target | Public mechanism |
| --- | --- | --- |
| TypeScript AI SDK | `ai 7.0.99`, `@ai-sdk/provider 4.0.14`, `@ai-sdk/openai 4.0.66` | `LanguageModelMiddleware` v4 / `wrapLanguageModel` / `generateText` / `streamText` |
| Python OpenAI | `openai 3.13.0`, Python >=3.10 | `OpenAI` / `AsyncOpenAI`, Chat Completions `create` and returned stream lifecycle |
| Python LangChain | `langchain-core 1.6.3`, `langchain-openai 1.6.2` | public `Runnable` / message conversion / invoke, async and stream forwarding |

版本来源为第一方 [AI SDK registry](https://registry.npmjs.org/ai/7.0.99)、[provider registry](https://registry.npmjs.org/@ai-sdk/provider/4.0.14)、[OpenAI Python registry](https://pypi.org/pypi/openai/3.13.0/json)、[LangChain Core registry](https://pypi.org/pypi/langchain-core/1.6.3/json) 和 [LangChain OpenAI registry](https://pypi.org/pypi/langchain-openai/1.6.2/json)。AI SDK provider 发布包的 `src/language-model-middleware/v4/language-model-v4-middleware.ts` 实际定义 v4；不能沿用 MemWal 0.1.6 v2/v3 的 `any` 注释宣称兼容。版本、发布包摘要和已读取类型的来源会随首轮安装测试记录。

## Binding and call context / 固定绑定与单次上下文

建议公开 TypeScript 入口 `createVelaMemoryMiddleware(binding)` 返回 `{middleware, close}`，供 `wrapLanguageModel` 使用；每次应用 turn 通过 `forTurn(context)` 创建 middleware 上下文，明确 session/turn 身份。不把 scope 或审批状态放进可被模型生成的 tool 参数。Python 提供独立 `VelaOpenAIChat` 和 `VelaLangChainModel`，构造时绑定 memory config；调用时显式 `MemoryTurn`，不修改原始模型对象。

`binding` 必填：

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

远端 memory binding 作为显式 union 分支：使用被冻结的 Walrus profile 与 factory，由当前远端 SDK 管理凭据/Worker/预览；不从本地 binding 自动升级。该分支的 namespace 是组织分区，不是 delegate ACL。模型与 embedding/relayer 接收方分别列出，不能混成一个隐含云服务。

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

公开 `MemoryReceipt` 拟包含：

```ts
type MemoryReceipt = {
  version: 1;
  turnID: string;
  scope: { project: string; namespace: string };
  modelRecipient: { provider: string; model?: string; origin?: string; recipientVerified: boolean };
  recall: { state: 'used' | 'empty' | 'skipped' | 'degraded' | 'failed'; ids: string[];
    usedBytes: number; filteredCount: number; truncated: boolean; indexComplete: boolean | null };
  generation: 'pending' | 'finished' | 'failed' | 'cancelled' | 'incomplete';
  capture: { state: 'disabled' | 'skipped' | 'candidate' | 'awaitingReview' | 'acceptedJobs' | 'failed' | 'uncertain';
    candidateIDs: string[]; jobIDs: string[]; effectsUnknown: boolean };
};
```

具体代码类型以实际固定宿主类型检查为准；不能以该草案承诺已经导出符号。Receipt 的普通日志不包含 prompt、记忆原文、模型输出、key、原始 provider error。`forTurn` 返回单次 `receipt()` 和可等待 `settled()`；`settled()` 必须在生成/流/capture 结束、失败或取消后完成，不留下永久 pending promise。

成功终态后、本地 `autoCapture: true`：只保存本次原始用户文本的筛选结果，使用 `memory.integration.capture` 原子 create-only。candidate 不进入下一次召回，直到用户审核 active；记录不是 analyze 模型事实。模型返回空值/拒绝/错误/未知 finish 类型、流未读尽或中止时不自动保存。保留输出/工具/usage 原样，禁止为了提取事实额外发一次模型调用。

远端 analyze 需单独 `reviewAnalyze(preview)` callback。预览冻结原始用户文本、namespace、relayer/embedding recipients、operation ID 与预算；callback 明确返回同 preview 的批准结果才 execute，拒绝和取消无上传。callback 不得自行调用隐藏写方法绕开 receipt。返回 jobs 仅表示服务接受，durable 需后续 status。远端未知副作用禁止自动 retry。

流式封装保持背压，不聚合完整输出；观察公开 finish/error/abort 事件以定终态。提前停止迭代、reader.cancel 或显式 close 会关闭本次底层 stream。只关闭本包装器创建的 helper/stream，不关闭应用传入的模型 client。模型或网络端仍可能继续工作，receipt 不伪称已撤销费用或远端任务。

## Package acceptance matrix / 安装验收矩阵

所有项目目前均为**待执行**。单独 optional-SDK job，不作为默认 Mac runtime 依赖。测试使用固定新 helper SHA、临时 stores/venv/Node consumer、合成模型凭据、loopback URL；不读取真实用户 home/config/key，不连接外部模型、Walrus 或 faucet。

| Scenario | Actual host path | Expected evidence |
| --- | --- | --- |
| Actual injection and preservation | AI SDK generateText, OpenAI create, LangChain invoke | loopback request body contains same namespace active memory; tool schema/options/attachments/order unchanged |
| Streaming completion | AI SDK streamText, OpenAI sync/async stream, LangChain stream/astream | original chunks/usage/finish remain available; bounded memory; candidate appears only after terminal consumption |
| Capturing disabled | every host, default configuration | Core has no new candidate, no remote callback/upload |
| Candidate and replay | successful nonstream/stream, repeated explicit turn ID | candidate-only original user text; deterministic ID, prior review retained |
| Failure/cancel/early close | actual provider error and partial SSE, client abort and iterator break | no auto capture; resources close; receipt settles, model outcome not retried by wrapper |
| Scope/private boundaries | two namespaces/agents/projects, malformed private fields | cross-scope/candidate/private absent from transmitted model input |
| Filters and framing | custom redaction/drop/throw/oversize + malicious tags | source remains fixed; no container breakout; bounds enforced; explicit degraded/failed receipt |
| Concurrent turns | same model across two independent bindings | no shared prompt/capture state, response receipts match turn |
| Unsupported/unknown shapes | typed fixture plus actual SDK validation | reject before provider dispatch; no coercion of arbitrary objects to prompt text |
| Remote analyze review | synthetic approved/rejected callback and signed loopback SDK | exact preview once, jobs accepted meaning, uncertainty and no automatic resend |
| Installed package | npm pack/temp consumer/tsc and wheel/temp venv imports | explicit package member allowlist, package/helper/version hashes, no source/tests/credentials shipped |

根 SDK 当前 12 TS / 10 Python 与可选 Walrus 32 项验证是已有证据；它们不能用作本合同尚未实现的 middleware 验收。Python Responses、Realtime、旧 AI SDK v2/v3、任意 LangChain 私有扩展或多模态内容理解需各自后续合同与实际运行测试，不能通过代理对象转发就宣称完成。用户要求的完整参考覆盖继续保留；此处只明确本次固定宿主实现顺序和精确验收边界。

## English summary

This is a planned public contract, not an implemented package claim. Each call binds explicit project/namespace and model recipients, preserves the original model request, injects bounded filtered references, and reports recall, generation and capture separately. Capture defaults off; successful local capture creates candidates only, while remote analysis requires an exact reviewed callback. Public framework methods, actual installed packages, synthetic loopback model requests, abort/resource behavior and scope-negative cases are required acceptance.
