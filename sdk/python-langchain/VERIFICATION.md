# LangChain acceptance / LangChain 验收

2026-09-13. This is an independent optional SDK slice. It does not replace the separately frozen Responses/AI SDK receipts or claim complete Walrus parity.

- **36/36** actual installed LangChain/ChatOpenAI HTTP/SSE integration tests with an explicitly selected real Vela helper. This includes sync/async invoke, real public Runnable/LCEL and bind_tools/with_config composition, streaming EOF, privacy, namespace isolation, failure/cancellation, transport ownership, concurrency and mutation uncertainty.
- **13/13** installed base Python SDK compatibility tests, including the exact `langchain` source and unknown-source zero-write boundary.
- **1/1** separately installed retained pre-LangChain base SDK wheel. Read-only generation still works; capture rejects before a model request or write.
- **7/7** Core MemoryIntegration test methods on copied source with the **portable fallback, not XCTest**. Snapshot: `770b5f355cc92bac267d6052daac838e53bd5a0850ef5d164a801c4e381199c8`.
- A clean base-only consumer imports Vela/LangChain Core with **neither openai nor langchain_openai installed**. Only the explicit `openai` extra installs the provider. No Python dependency enters the default Mac app.

Versions: Python **3.14.7**, `langchain-core==1.6.3`, `langchain-openai==1.6.2`, `openai==3.13.0`. Exact installed dependency versions are retained in the receipt directory. The helper was independently built from **76 frozen source/package/resource files**, snapshot `22f9980e85ca24d7f32a9fa82fe2d4edbc3785bf6c6898690b085fd1fbe500a6`; source manifest file SHA `71be409ff940dccf7df8cbd1a42210e76bc871b079e9a883d9e6d07e23aa7ed6`. Build time was 95.61 seconds, not a runtime performance benchmark.

| Artifact | SHA-256 | Bytes |
| --- | --- | ---: |
| LangChain wheel v2 | `3821bf1358fa3aaff5c41a9e18a89ce7a3431000560f71231e8937abb278c8fd` | 23,448 |
| Base Python SDK wheel | `48c904ed65fed5a536c4491aaf13b9fab227db8ba99282205a6debafe23d52cd` | 12,359 |
| Frozen helper | `baba2f50ec88f2d8c85260b93648f1daf6ac998ab617d4a7b39d2915c7ee7028` | — |
| Retained pre-LangChain base wheel | `5d91784970fdf32c76bcce7e5ffabab52e702df8bbf5ef580e98a1e8d74dd77e` | — |

Independent review reproduced two defects against the retained **v1** wheel: mixed string/dictionary human text blocks changed order in query/capture, and public default header/query mutations after snapshot changed the actual request. Both occurred through all four provider entry points. V2 preserves block order and uses explicit copied SDK default mappings, while checking root/model configuration consistency. Dynamic sync/async credential providers remain callable at request time. Its tests also verify that unexpected distinct root defaults reject instead of being silently dropped. The old wheel and four failing regression methods are retained; an earlier passing matrix does not override those findings.

The installed matrix includes the earlier Responses review scenarios: original-client endpoint/model/tool mutation, preflight zero dispatch, and real committed candidates followed by malformed success acknowledgements. Scope/capability fixture cases are labeled as such; all normal candidate/recall cases use the real helper. Lost and malformed acknowledgements remain uncertain without mutation retries. Provider messages, stream events and normal caller clients are exercised through actual official SDK classes, not fake model stand-ins.

Evidence: `sdk/python-langchain/evidence/installed-v2/package-results.json`, `source-freeze.json`, `module-byte-verification.json`, test/install/dependency logs and both wheels; `evidence/core-integration-v1.json`, `frozen-build-v1.log`, `source-snapshot-v1/source-manifest.json`, `helper-preservation.json`, `consumer-counterexamples-v1.log`. The retained executable is `evidence/frozen-helper`. Source and installed runtime bytes were compared, and the owned Core/test files match the compiled helper snapshot. Runtime wheels contain only explicitly allowed modules/type marker and distribution metadata/license, excluding tests, plans, evidence and credentials.

Reproduce with `python3 scripts/test-langchain-integrations.py`. Select a fixed helper with `VELA_LANGCHAIN_HELPER` and its source manifest with `VELA_LANGCHAIN_SOURCE_MANIFEST`. Set `VELA_LANGCHAIN_LEGACY_SDK` for the optional actual-old-wheel case; omission is reported as not run. Each run gets a separate evidence directory and creates/removes its disposable consumer environments, copied helpers, synthetic stores and pip cache. The reusable optional development environment, source/evidence, wheels and retained helper are preserved.

This proves the stated ChatOpenAI Chat Completions integration and local memory boundary. It does not prove external model quality, provider network identity, opaque/dynamic Runnable routing, other provider adapters or remote Walrus operations. Synchronous cancellation is limited by public provider timeout/retry/callback behavior; wrappers do not close shared transports or claim a remote rollback. Upstream LangChain may retain stream chunks internally; the wrapper does not claim otherwise.

中文：该切片提供可安装、可复验的 LangChain 标准入口；默认 Mac 依赖保持不变。正式 v2 完整验证 36 项宿主、13 项基础 SDK、1 项旧 wheel 及 7 项 Core portable，并保留 v1 的两个真实反例。仅把明确测试过的 ChatOpenAI 路线列为完成，继续保留其它 provider、动态图和远端能力的验收边界。

Independent v2 consumer recheck passed 7 selected installed regression methods, an 8-case matrix across the four entry points, and 4 additional streaming defaults-conflict/dynamic-key cases. Every matrix also checked the original caller client remains usable after wrapper close. These are reported separately, not added to the 36-method host count. Receipt: `output/parity/langchain-independent-review-v2.json`, SHA `9e96e0259cab18dadda88b0d50faa8a8af5c49a17a55a7d261817196dfe53054`. It includes the retained v1 four-entry-point counterexamples and explicit cleanup of all 12 independent temporary fixtures. No further defect was identified in those reviewed boundaries.
