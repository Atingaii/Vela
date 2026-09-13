# Python Responses acceptance / Python Responses 验收

2026-09-13. This is a separate slice following the frozen TypeScript AI SDK package; it does not rewrite that checkpoint or claim all reference products are complete.

- **30/30** installed Responses tests with official OpenAI Python **3.13.0**, Python **3.14.7**, loopback HTTP/SSE, synthetic credentials and an explicitly selected real Vela helper. Legacy/malformed capability and foreign-record cases are clearly labeled helper fixtures.
- **12/12** installed base Python SDK compatibility tests, including the new exact source union and unknown-source zero-write rejection.
- **1/1** separately installed retained pre-Responses SDK wheel: default read-only generation works; auto-capture fails before a model request or write.
- **6/6** Core integration methods on a copied source snapshot using the portable fallback runner, **not XCTest**. The runner snapshot is `25e5992dc70a9474a3da9553c36a417c4b41ac4b875bc570a16284f5e567094f`.

The helper was built independently from **116 frozen source/package/resource files**, snapshot `a4e69652d508ee9108eee4456c0b8afdb6f06e79bf719e5c6fc6e013943a3642`. This avoids using a binary compiled while the shared worktree changes. The Responses Core/test files matched that snapshot at the earlier freeze. This consumer fix reuses the same independently built helper and frozen base SDK source; ongoing LangChain additions in the shared worktree are excluded. Core tests were not rerun for this Python-only fix; the 6/6 result above remains the earlier source snapshot evidence.

| Artifact | SHA-256 | Bytes |
| --- | --- | ---: |
| Python Responses wheel | `02a4824af5b169949c1345090cbd7eb3d3026f41d6348ab0837bda515ef54430` | 19,038 |
| Base Python SDK wheel | `5d7435e54bf444a55da206f10208a54e28d7222f6de33a5c2cee54f59a51d165` | 12,335 |
| Frozen helper | `af5bdfd282ab8a69e21c67b5a8d750c880018d1451096b23367f6ccf104212d0` | — |
| Retained legacy SDK | `964752ffb5ecf3ee708345e9b76a32ded455fcabe712ace4651cf4d2a7bb3ce9` | — |

Installed module bytes were checked against the frozen source. Wheels use an explicit member allowlist: only runtime modules/type marker and distribution metadata/license. Build inputs, tests, internal evidence and credentials are excluded.

Coverage includes sync/async generation, actual typed Response.output history, preserved instructions/tools/image parts/options, default zero capture, exact namespace/non-private filtering, reviewed-candidate replay, terminal event plus EOF, early close/task/Event cancellation, shared client ownership, concurrency, custom filtering and limits, failures/refusals/incomplete streams, and lost acknowledgements after real capture commits. Cancellation during both nonstream and stream-EOF capture retains uncertain effects and finalizes its receipt.

A strict-type defect was reproduced against the installed v3 wheel: string/dictionary `supportedIntegrations` could be interpreted as supported under optional degraded memory mode. The isolated failure remains in `evidence/capability-counterexample.log`. The earlier v4 fixed that issue and accepts only bounded string arrays from Core and the expected immutable SDK capability set; the complete installed matrix passes with string/dict/mixed-array negative cases. Earlier snapshots remain independently preserved.

The earlier v4 was then independently found to permit shared-client endpoint mutation between validation and dispatch, to count preflight rejections as model calls, and to lose mutation uncertainty on semantically invalid success acknowledgements. Those failures are retained in `evidence/endpoint-counterexample-v4.log` and `evidence/malformed-ack-counterexample-v4.log`. The final v6 uses public per-request `with_options(base_url=...)` copies, dispatch/attempt counters, and strict acknowledgement validation. Its six added sync/async methods also exercise create/stream endpoint isolation and the still-usable caller HTTP transport.

Evidence: `sdk/python-ai/evidence/installed-v6/package-results.json`, `source-freeze.json`, `base-compatibility.json`, `actual-responses-tests.log`, `legacy-tests.log`, wheels; `evidence/core-integration-v2.json` and the frozen build/source manifest. The retained helper is `sdk/python-ai/evidence/frozen-helper`. All disposable consumer installs, helper copies, synthetic stores and caches from the runner are removed. The frozen helper/source/evidence and reusable optional development environment are retained; the source snapshot's temporary Swift build directory is removed after preserving the helper.

Reproduce with `python3 scripts/test-python-ai-integrations.py`; select a separately built helper via `VELA_PYTHON_AI_HELPER` and its source manifest via `VELA_PYTHON_AI_SOURCE_MANIFEST`. For this checkpoint, `VELA_PYTHON_AI_BASE_SDK` selected a complete source stage reconstructed with the root's frozen Responses SDK files. Every uncompressed base-wheel member matches the retained v4 base wheel; only ZIP-container timestamps differ. Optionally pass `VELA_PYTHON_AI_LEGACY_SDK` to run the legacy wheel case. Without the optional artifact, that case is explicitly not run. Each execution writes a separate evidence directory.

中文：独立复核发现的接收端竞态、无请求误计数和畸形成功回执误报均已修复，并用新安装包重验。原 v4 失败证据保留。该结果证明官方 Responses SDK 与真实本地 Memory 的接入闭环，不代表外部模型质量、LangChain、远端 analyze 或完整 Walrus parity。同步 SDK 在 headers 前没有公共逐请求强制取消句柄，测试验证了 timeout/Event 边界，未声称立即取消服务端或回滚写入；模型 client 始终由应用所有。AI/SDK 包与固定源码 helper 的摘要均已保留，可以独立验收。
