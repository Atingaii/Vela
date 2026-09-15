# px0 workflow source audit — 2026-09-13

## Scope and method

This is a read-only source audit of the separately fetched, public px0
workflow repository at commit `df7e6eba9df7759cb0c924ac84563a7874bfb051`.
The sibling px0 IDE-oriented main branch was deliberately not used.  No px0
installer, hook, daemon, browser extension, account flow, or third-party test
was run.  The audit does not copy px0 code or prompts into Vela.

The 120 rows in [px0.md](px0.md) stay unchanged.  Their source-level mapping is
in [px0-source-audit-2026-09-13.csv](px0-source-audit-2026-09-13.csv).  Each CSV
row has one of the evidence keys below, which resolves to concrete public px0
code and a visible reference test, plus a Vela implementation/test key.
`implemented_bounded` means Vela has a concrete, bounded implementation and
relevant local verification; it does **not** claim identical UX, external-account
compatibility, or release acceptance. `partial` and `missing` remain open.

## 中文摘要

审计仅阅读固定公开源码提交 `df7e6e…b051`，没有安装或运行 px0。CSV 恰含
原台账的 120 个唯一 ID：31 项为有边界实现及本机证据、66 项为部分覆盖、19 项
缺失，另保留 macOS 平台差异、MCP 执行的刻意限制和 px0 自身两项未接通/冲突。
每行以证据键关联到下表的具体 px0 源码与可见测试，以及对应 Vela 源码/测试。
这不是产品验收完成声明。

## Reference evidence keys

| Key | Public px0 implementation and visible tests |
| --- | --- |
| `PX-BUILD` | `px0/builder.py`, `px0/workflow.py`; `tests/test_builder_discovery.py` covers bounded interview, tool selection, guideline selection and request revision. |
| `PX-RUN` | `px0/runner.py`, `px0/workflow.py`, `px0/runs.py`; `tests/test_failure_path.py`, `tests/test_resilience.py`, `tests/test_sync_and_pipelines.py`. |
| `PX-DAEMON` | `px0/daemon.py`, `px0/status.py`; `tests/test_daemon_logs.py`, `tests/test_watch_triggers.py`, `tests/test_failure_path.py`. |
| `PX-TOOLS` | `px0/tools.py`, `px0/connect.py`, `px0/localtools.py`, `px0/catalogue.py`; `tests/test_builder_discovery.py`, `tests/test_tools_composio.py`, `tests/test_composio_execution.py`, `tests/test_connect_composio.py`. |
| `PX-APPROVAL` | `px0/approvals.py`, `px0/inbox.py`, `px0/notify.py`; `tests/test_approvals.py`, `tests/test_failure_path.py`, `tests/test_inbox_memory.py`. |
| `PX-BRAIN` | `px0/brain.py`, `px0/retrieval.py`, `px0/memory.py`; `tests/test_brain_ingest.py`, `tests/test_brain_index.py`, `tests/test_retrieval_qmd.py`, `tests/test_brain_vault.py`. |
| `PX-ASK` | `px0/route.py`, `px0/ask.py`; `tests/test_route_and_agent_loop.py`, `tests/test_ask_consumer_contracts.py`. |
| `PX-HEALTH` | `px0/analysis.py`, `px0/improve.py`; `tests/test_analysis.py`, `tests/test_improve.py`, `tests/test_feedback_loops.py`. |
| `PX-STORE` | `px0/store.py`, `px0/sync.py`, `px0/versioning.py`, `px0/config.py`, `px0/cli.py`, `px0/parser.py`; `tests/test_sync_and_pipelines.py`, `tests/test_resilience.py`, `tests/test_cli_shape.py`, `tests/test_doctor_fixes.py`. |
| `PX-MEETING` | Added by the audited commit: `px0/audio.py`, `px0/meeting_server.py`, `px0/brain.py`, `px0/parser.py`, `extensions/chrome-meet-trigger/{manifest.json,content.js}`; `tests/test_audio_recording.py`, `tests/test_brain_ingest.py`, `tests/test_brain_index.py`. |

## Vela evidence keys

| Key | Current Vela implementation and local evidence |
| --- | --- |
| `V-PLAN` | `Sources/VelaCore/WorkflowPlanning.swift`, `RestrictedCodexProposal.swift`; `Tests/VelaCoreTests/WorkflowPlanningTests.swift`. |
| `V-WORKFLOW` | `AutomationService.swift`, `WorkflowContext.swift`, `WorkflowComposition.swift`, `WorkflowManagement.swift`; their corresponding `Tests/VelaCoreTests/*Tests.swift`. |
| `V-RUNTIME` | `AutomationProcess.swift`, `RuntimeShutdown.swift`, `SchedulerService.swift`, `DaemonService.swift`, `WorkflowWatch.swift`, `WorkflowFileWatch.swift`; focused tests and retained checkpoint portable evidence. |
| `V-CONNECTOR` | `ConnectorService.swift`, `ConnectorTransport.swift`, `MCPTools.swift`, `MCPToolAccess.swift`; `ConnectorTests.swift`, `MCPToolsTests.swift`, and checkpoint MCP receipts. |
| `V-APPROVAL` | `AutomationService.swift`, `Store.swift`, `SafeApply.swift`; `ApprovalRecoveryTests.swift`, `AutomationTests.swift`. |
| `V-LIBRARY` | `LibraryService.swift`, `LibraryIndex.swift`, `MemoryService.swift`, `SemanticMemory.swift`; `Library*Tests.swift`, `SemanticMemoryTests.swift`. |
| `V-ASK` | `KnowledgeQueryService.swift`, `AutomationService.swift`; `KnowledgeQueryTests.swift`, `scripts/test-ask-consumer-contracts.py`. |
| `V-IMPROVE` | `ImproveService.swift`, `ModelImprovement.swift`, `ReplayFixture.swift`, `WorkflowReplay.swift`; their test suites. |
| `V-STORE` | `Store.swift`, `Preferences.swift`, `Sources/VelaCLI/main.swift`; `FoundationTests.swift`, `IntegrityTests.swift`, `scripts/test-rpc.py`. |
| `V-NONE` | No current Vela implementation or no evidence sufficient for the px0 semantics. |

## Findings that change the backlog

The original 120-item inventory covers the broad Ask route (`PX0-085`), retry
(`PX0-023`, `PX0-052`) and health analysis (`PX0-092`–`095`) surfaces.  The
source audit confirms those are real px0 code paths, rather than website-only
claims.  Vela has bounded alternatives in several places, but does not yet
close px0's model-selected Ask router, per-attempt retry/backoff policy, or
health finding/fix loop.

The audited commit adds a separate delivered workflow surface that the 120 rows
do not name: live audio capture, local transcription, meeting-note creation and
brain indexing, with an optional Chrome-triggered localhost daemon.  It should
be added as *new* scoped backlog rather than silently folded into YouTube
transcripts or generic daemon items:

| Proposed increment | Reference binding | Vela assessment |
| --- | --- | --- |
| `PX0-SRC-121` local meeting/audio import and transcription | `PX-MEETING`; `px0 brain record` is registered in `px0/parser.py`; audio suffixes route through `px0/brain.py` | Missing. Vela Library supports text/document imports, not a local audio capture/transcription pipeline. |
| `PX0-SRC-122` live meeting recording lifecycle and indexed note | `PX-MEETING`; `LiveMeetingRecorder`, `MeetingServer._process_recording`, `tests/test_audio_recording.py` | Missing. This also needs an explicit privacy, retention, device and model-download design before implementation. |
| `PX0-SRC-123` opt-in browser meeting trigger to a loopback listener | `PX-MEETING`; Chrome MV3 manifest and `content.js` POST/beacon calls to `127.0.0.1:8765` | Missing and not implicitly authorized by existing Vela daemon work. It is a new browser-extension/local-listener trust boundary. |

## Ten highest-impact open items

1. `PX0-003/005/037–052`: a frozen connector catalogue, real account lifecycle
   and provider-verified read/write behavior remain incomplete; current
   ConnectorService safety tests do not establish real account compatibility.
2. `PX0-023`: Vela deliberately does not implement automatic retries for
   uncertain side effects; px0's bounded retry/backoff needs a separately safe
   operation taxonomy before parity can be claimed.
3. `PX0-032/033`: Vela has local Git/Memory/Library/file watches, but not px0's
   arbitrary read-tool catalogue scope.
4. `PX0-055/058`: Vela's reviewed agent loop exists, but full scoped-MCP
   execution and continued output around each queued write are not equivalent.
5. `PX0-069/070/072`: YouTube, playlists and vault ingestion are absent.
6. `PX0-078/085/086`: Vela Ask is a reviewed knowledge-query service; it is not
   px0's route selection and durable conversational front door.
7. `PX0-092–095`: no px0-like evidence-derived Health report and narrow,
   revertible repair path is implemented.
8. `PX0-098/099`: Vela's consented historical replay is intentionally not a
   two-version model evaluation with output churn comparison.
9. `PX0-102–105`: memory archives are not complete store export/import or
   bidirectional conflict-resolving sync.
10. `PX0-SRC-121–123`: the audited commit's local meeting/transcription/browser
    trigger surface is entirely outside current Vela implementation.

## Verification boundary

Reference tests were inspected for test intent and named assertions only; they
were not run.  Vela evidence is current source plus retained local tests, in
particular `output/parity/relations-history-checkpoint-final.json`, not an
assertion of UI, website, package, external account, or macOS permission
acceptance.
