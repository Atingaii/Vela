# ADR 0026: Optional model memory middleware / 可选模型记忆中间件

- Status: Accepted for local TypeScript AI SDK v4; Python and reviewed remote analyze remain proposed
- Date: 2026-09-13
- Scope: Optional TypeScript/Python packages, model input and candidate capture boundary

## Context / 背景

Walrus Memory 的公开集成在生成前取最后一条用户文本、召回记忆并注入，生成后可调用 analyze 保存。Vela 已有本地 namespace API、安装后的 SDK 和 OpenClaw 插件，但这不构成 Vercel AI SDK、OpenAI Python 或 LangChain 的集成覆盖。下一阶段应完成这些实际宿主路径，仍保持默认 macOS runtime 不新增 Node/Python 或模型依赖。

第一方 [MemWal AI SDK 文档](https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/sdk/ai-integration.md) 与 [Python 集成文档](https://github.com/MystenLabs/MemWal/blob/493c9e66851e1b542ce5f55a547827f64e141c45/docs/python-sdk/usage/with-memwal.md) 描述的是集成行为，不能代替当前模型 SDK 的类型兼容验收。已发布 MemWal 0.1.6 的中间件类型用 `any` 兼容 v2/v3；其 Python 文档描述修改模型 `_generate/_agenerate`。这些实现方式不适合作为 Vela 新公共接口的兼容保证。

## Decision / 决策

新增可选 TypeScript `sdk/ai` 包，使用公开 `wrapLanguageModel` 和 `LanguageModelMiddleware`；新增独立 Python 集成包 `sdk/python-ai`，以公开 OpenAI Chat Completions 调用和 LangChain `Runnable` 组合封装模型。两个包只依赖各自所需的 SDK；Python 框架依赖按 extras 安装、延迟导入。它们不修改调用者模型对象，不替换类的私有方法，不新增服务器或 agent framework。

首个固定测试基线为 `ai 7.0.99`、`@ai-sdk/provider 4.0.14`、`@ai-sdk/openai 4.0.66`，Node >=22；Python `openai 3.13.0`、`langchain-core 1.6.3`、`langchain-openai 1.6.2`，Python >=3.10。这些是 2026-09-13 registry 查询及实际发布包类型读取的结果，TypeScript 组合已完成真实安装验证；Python 组合尚待实现与验证。AI SDK 当前公开中间件类型为 `specificationVersion: 'v4'`，该类型仍标为 experimental。Vela 先对固定版本完成真实安装/类型/运行测试；后续主版本必须重新验收，不能用 `any` 或宽松版本号宣称兼容。

当前 TypeScript binding 固定显式 project/namespace 与本地 helper/store；显式远端 profile 是后续独立接口，不在当前包中伪造支持。模型、provider 凭据和连接由应用传入。调用方必须声明模型接收方；中间件会把经筛选的记忆交给该模型，但不会把自报名称当作已经证明的网络接收方。可取得的公开 provider/model ID 或 OpenAI base URL 必须和冻结描述核对；不能检查的自定义模型会在 receipt 中明确 `recipientVerified: false`。该声明不取代应用自己的 provider/网络控制。

召回只以最后一条用户消息的文本部分为查询，不把 tool、assistant、图片、文件或音频转换为文本。默认本地 active/non-private/exact namespace 隔离来自 Core。既有 system/developer 指令、消息顺序、工具参数、附件和 provider options 保留。新增记忆以有界、不可信引用块附于当前用户文本上下文，不提升为 system/developer 权限。框架适配按实际消息格式处理；不支持的消息格式在模型调用前显式报错。

提供调用方可扩展的纯文本过滤：查询、待注入记忆和候选捕获分别过滤，返回文本或 null。过滤不能新增来源、扩大 scope 或绕过最终字节上限/转义/隐私边界；异步过滤需受调用 deadline/abort 约束。默认防回声、凭据模式筛选与不可信 framing 是工程防护，不是模型服从的形式证明。receipt 保留过滤/截断数量，不记录原始 prompt 或密钥。

`autoCapture` 默认关闭。明确打开本地捕获后，只有成功完成的生成才把本次原始用户文本写为 candidate；不捕获模型输出、注入文字或工具文本，不自动改 active。capture source ID 绑定显式 session/turn、scope 与原始文本摘要，重试/多步调用复用同一 ID，使用 Core 原子 create-only 保留审核状态。每次调用返回可等待的 capture receipt；不以无主后台任务 fire-and-forget。失败、取消、不完整流、未知 finish 状态均不自动捕获。

远端 analyze 始终另走 reviewed callback：生成完成后准备冻结原文、接收方、namespace 和预算预览；调用者明确接受后才执行。拒绝/无 callback/超时不上传。只接收到 jobs 不能称为 durable，也不能将 candidate 原文捕获称为模型事实提取。跨进程远端 journal 仍须在独立生命周期工作中完成。

流式结果逐块转发，不积累完整模型输出；捕获依据模型流实际终态，不以获取 stream 对象当成功。调用者通过 AbortSignal 或 close 关闭本次 owned stream 和本次 helper；AI SDK 的下游 tee/iterator 提前退出未必取消 provider，不能把它等同于显式取消，保留原模型 client 所有权。取消表示本地停止消费；不能声称核心副作用或远端模型任务已回滚。模型的重试行为由应用配置，Vela 不新增重试；合成验收将 provider retry 设为 0。

当前 Core `memory.integration.capture` 只接受明确的 `openclaw` 和 `ai-sdk-v4` 标识，写入实际 provenance；scoped stats 返回支持列表。SDK 导出冻结列表，AI 捕获在模型调用前核对 SDK/Core 支持。未知和旧来源组合明确拒绝，绝不降级标成 OpenClaw。名称是来源声明，不是宿主认证或 ACL。

## Alternatives / 取舍

- 直接复用 MemWal 中间件会隐含默认 namespace、远端处理和 SDK 自身自动保存，难以保留 Vela 的 candidate 审核、显式接收方与本地路径，因此复用其公开能力合同，而不直接套入默认实现。
- 修改 Python 模型私有方法表面上接近原 API，但会影响共享模型对象、流式分支和未来版本；采用公开 Runnable/请求包装，保留实际模型对象和调用参数。
- 统一成任意 callback 框架会把关键上下文/失败语义留给应用猜测；先交付三个固定公共宿主适配器，内部仅共享确有复用的过滤、framing 和 receipt 逻辑。
- 自动提取全部对话可增加保存量，但会扩大原文离机、反馈回声和错误事实风险；保留可审核远端 analyze 入口，并用候选原文闭环提供本地默认能力。

## Verification / 验证

验收使用打包后的真实 consumer，不直接 import 源文件；执行实际 AI SDK `generateText/streamText`、OpenAI sync/async 和 LangChain `invoke/ainvoke/stream/astream`。模型服务为隔离 loopback HTTP/SSE 合成 provider，接收端核对实际请求中的同 namespace 引用、顺序/工具/附件保真及敏感/跨域负例。合成响应只证明宿主与协议路径，不构成真实模型质量证据。

必须覆盖关闭捕获零写、完整终态 candidate、提前结束/失败零写、同 turn 重放幂等、流式背压与关闭、并发作用域隔离、过滤器拒绝/异常、未知格式拒绝、超限截断和错误脱敏。remote reviewed callback 独立测试接受/拒绝/未知结果、无隐式上传。安装计划和完整矩阵见 [接口合同](../implementation/model-memory-middleware-contract.md)。当前 TypeScript 的 17 项安装后真实宿主测试、12 项本地 SDK 兼容测试及 5 项 Core 定点已经通过，精确包和 helper SHA 见 `sdk/ai/VERIFICATION.md`。它们覆盖真实 HTTP/SSE、候选提交后响应丢失的 uncertain 回执和未发送重试；Core 定点在本机为 portable fallback，不能称为 XCTest。Python、远端 analyze 与外部模型质量仍待独立验收。

## English summary

The implemented optional TypeScript package uses public AI SDK v4 middleware; Python OpenAI/LangChain composition remains proposed, with pinned host versions verified before broader compatibility claims. Explicit scope and model recipients, extensible text filters, bounded untrusted framing, default-off candidate capture, terminal-stream handling and reviewed remote analysis preserve Vela's memory boundary. Existing model objects are never monkeypatched. Installed TypeScript package tests exercise real AI SDK requests to a synthetic loopback provider and actual helper reads/candidate writes. Python, model quality and remote encrypted persistence require separate implementation and evidence.
