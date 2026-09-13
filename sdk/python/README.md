# Vela Python SDK

A Python 3.10+ sync/async client for the explicitly selected local Vela helper and store. Uses the Python standard library only at runtime. This development package has not been published to PyPI and is not bundled with the Mac app.

From the Vela repository:

```sh
python3 -m pip install ./sdk/python
```

```python
from vela import LocalTransport, VelaClient, AsyncVelaClient, VelaError, VelaBulkError

transport = LocalTransport(
    executable='/Applications/Vela.app/Contents/MacOS/vela',
    home='/absolute/path/to/.vela-dev',
)
with VelaClient(transport, project='/absolute/path/to/project') as client:
    client.register_project('/absolute/path/to/project')
    memory = client.save_candidate({
        'title': 'Verification command',
        'content': 'Run project verification before publishing.',
        'type': 'constraint',
    })
    archive = client.export_archive()['archive']
    client.validate_archive(archive)
    memories = client.list_memories()

async def use_memory():
    async with AsyncVelaClient(transport, project='/absolute/path/to/project') as client:
        return await client.recall('verification', budget=2000)
```

Both clients expose `list_projects`, `register_project`, `list_memories`, `recall`, `save_candidate`, `save_candidates`, `export_archive`, `validate_archive`, and `import_archive`. Memory writes/imports create candidates; activation is a separate human review operation in Vela. Recall uses the selected helper's actual local capabilities, not a SDK-side semantic model.

The synchronous client serializes requests. The async interface runs the same transport off the event loop, with at most 32 queued/in-flight calls per client. Do not share one async client across event loops. `timeout` is in seconds, greater than zero and at most 120, default 15. It includes waiting for the serialized connection.

`VelaError` has `code`, `request_id`, and `effects_unknown`. On a timeout, malformed/oversized output, disconnect, or explicit close, the owned helper/process group is terminated. No request is retried or connection reopened. A started write may already have taken effect; inspect the store before deciding on recovery. Async cancellation raises `VelaCancelledError` with the same request/effects metadata and closes the shared connection. This is not evidence that a core operation was undone. Other waiting calls may fail as a consequence. Cancellation metadata belongs to the cancelled invocation: if it had not sent any bytes, `request_id` is null and `effects_unknown` is false. A different active write still reports its own request ID and uncertainty through its own failure.

`save_candidates` prevalidates 1–100 records and sends them sequentially, stopping on the first failure. It is **not atomic**. `VelaBulkError` reports `completed`, `failed_index`, `unattempted`, `skipped` (0), and its typed `cause`. Async bulk cancellation also reports this partial-result error. Use validated archive import for the Core's local all-or-nothing batch semantics. Checksums are preserved rather than repaired by the client.

Helper stdout is limited to 2 MiB per JSONL frame; stderr is drained with a 64 KiB connection limit. Neither raw output nor raw RPC error messages appear in SDK errors. The child starts with `rpc --no-watch --no-schedule` and discovery disabled, without a shell. Close/context-manager exit releases its streams, selector and process.

This SDK is an integration layer, not an access-control boundary. It uses existing local OS/helper/store authority; no owner/delegate ACL or remote identity is implied. `LocalTransport.type` only accepts `local`; future remote compatibility is a separately versioned interface. No arbitrary shell/filesystem or workflow execution endpoint is exposed.

Run `PYTHONPATH=sdk/python/src python3 -m unittest discover -s sdk/python/tests -v` from the repository after building `vela`. `VELA_TEST_HELPER` can select the helper explicitly. Tests use only synthetic fixtures and disposable stores.


Both clients also expose `semantic_index(language="en", batch_size=32, cursor=None)` and `semantic_status(language="en")`. Resume by passing `nextCursor` until `hasMore` is false, then inspect status; per-item failures and concurrent edits can leave an incomplete index. `recall(..., retrieval_mode="semantic" | "hybrid", language="en" | "zh-Hans", limit=20, min_similarity=0.2, scoring_weights={"semantic": 1, "recency": 0, "importance": 0, "recency_half_life_days": 30})` adds typed semantic options. Branch/worktree/task/session_id scope parameters remain available. Default recall remains lexical. Optional Apple model assets are never automatically downloaded. Check `status`, `indexIncomplete`, and `fallbackReason`; do not interpret unavailable assets as successful semantic recall. Indexing does not activate candidate memory.

## 简体中文

此包提供 Python 3.10+ 同步和异步客户端，运行时只依赖标准库，连接明确选择的 macOS helper/store，目前未发布到 PyPI，也不会增加 Mac 客户端运行依赖。

同步接口按顺序请求；异步接口在事件循环外使用同一传输，避免阻塞应用。超时单位为秒。两种接口都支持项目、候选 Memory、召回和归档；导入及普通写入不会直接激活记忆。

`save_candidates` 失败会保留已完成结果并停止后续写入，不是原子批次。取消/超时会结束自有 helper 进程组并释放资源，但写入可能已经发生；请检查 `effects_unknown` 和实际 store 状态，不能自动重发。异步批量取消也通过 `VelaBulkError` 返回已完成与未尝试项。取消元数据仅指本次调用；尚未发送的排队调用返回空 request_id 和 effects_unknown=false，受关闭影响的其他实际写请求仍通过自身异常报告不确定性。

SDK 固定关闭发现、监听和调度，不读取用户凭据或创建远端账户。它是接入层，不是新的权限系统；完整远端 owner、namespace ACL、加密同步仍按功能覆盖清单继续实现。

语义接口支持本机 English / 简体中文模型、显式分页索引、状态检查、semantic/hybrid 召回与可选时间/重要性排名。默认仍为词面检索；模型缺失和索引不完整均显式返回，不下载模型、不自动激活候选，也不代表远端加密记忆已实现。

Sync and async clients expose `archive_from_walrus_records(source, records)`. It constructs an archive from explicitly selected non-private Walrus UTF-8 records (`blobID/title/content/sha256/private:False`, optional reader `receipt`) without writing memory. Core checks plaintext SHA; remote identity/receipt remain caller-reported. Validate/import separately into a registered project as idempotent candidates. 中文：同步/异步接口均支持原始 Walrus 文本先构造归档，再显式候选导入，不自动激活，不替代私有完整备份。

### Scoped integration memory

Sync and async clients expose `capture_integration(namespace, source_id, records)`, `recall_integration(namespace, query)` and `integration_stats(namespace)`. Use an explicitly registered project. Capture creates candidate observations, never active facts; recall reads only the same namespace, active state and non-private content. This is a local process boundary, not remote authentication or a namespace ACL.

中文：同步/异步客户端均提供命名空间捕获、召回和真实统计；候选需审核后才可召回，SDK 不冒充外部宿主身份认证或远端 ACL。

`capture_integration(..., integration="openclaw" | "openai-responses")` now exposes the same exact keyword for sync and async callers. `MemoryIntegration` is the public Literal type; `MEMORY_INTEGRATIONS` is an immutable capability set. The compatible default remains OpenClaw. Unknown values fail before a write. Optional Responses middleware checks both the SDK capability and scoped Core `supportedIntegrations` before generation; the integration string is provenance, not host authentication. 中文：同步/异步捕获保留 OpenClaw 默认，并明确支持 Responses 来源；能力检查只读，未知来源在写入前拒绝，候选仍需审核。
