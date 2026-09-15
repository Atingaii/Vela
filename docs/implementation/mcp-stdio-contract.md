# Local stdio MCP contract

Vela provides project-scoped MCP tools through the existing local helper. This is the typed stdio slice of ADR [0029](../adr/0029-typed-stdio-mcp-tools.md). It does not provide HTTP/OAuth, remote accounts, model execution, workflow execution, or a remote archive service.

```sh
# Default read mode. Register the project in Vela first.
vela mcp --home /absolute/path/to/vela-store

# Explicitly allow local candidate/record contributions.
vela mcp --contribute --home /absolute/path/to/vela-store
```

All messages are UTF-8 JSON-RPC, one JSON object per line on stdin/stdout. Diagnostic output belongs on stderr. A client must send `initialize`, receive the negotiated version, and send `notifications/initialized` before listing or calling tools. `ping` is available before tool initialization. Notifications never execute contribution tools and never produce responses. No connection starts a model or reads provider account credentials.

## Version and envelope compatibility

Supported date versions: `2024-11-05`, `2025-03-26`, `2025-06-18`, `2025-11-25`. A supported requested version is returned unchanged. An unsupported date receives the latest supported version; the client must disconnect if it cannot use that version.

- Tool `annotations` are omitted for `2024-11-05`.
- Text content is present for every supported version.
- `structuredContent` is added for `2025-06-18` and `2025-11-25`. When the legacy text value is an array, its structured companion is `{ "items": [...] }`.
- Advertised capabilities contain only `tools`. Sampling, resources, prompts, asynchronous tasks, remote authentication and list-change notifications are not advertised.
- Request IDs must be strings or non-Boolean safe integers, non-null and unique within the connection. Reconnect after 8,192 requests. Reconnecting does not authorize retrying a contribution whose outcome is unknown.
- Unknown methods return `-32601`. Invalid envelopes return `-32600`; malformed MCP request parameters or unavailable tool names return `-32602`; tools before initialization return `-32002`. Tool input validation and business failures return a successful JSON-RPC envelope with `result.isError=true`.
- The CLI separately enforces line/request and queue bounds. Tool argument objects are additionally limited to 1 MiB and tool results to 512 KiB.

## Tool catalog

`tools/list` publishes the exact `inputSchema`; every object has `additionalProperties:false`. No tool accepts a shell command, arbitrary filesystem read/write path, activation flag, approval or connector execution payload. The catalog itself is bounded and has no continuation cursor.

| Default read tool | Result and scope |
| --- | --- |
| `vela_search` | A bounded scan page of current safe project evidence, with sanitized excerpts; legacy text array. The caller follows scan cursors until complete. |
| `vela_recall` | Active, scope-qualified project memories within a token budget; lexical or explicit local semantic/hybrid retrieval. Global memories are excluded. |
| `vela_memory_list` | Active memory summaries; `state:"candidate"` explicitly reviews candidates. Legacy text array. |
| `vela_setup_list` | Captured sanitized setup metadata, without a new scan or configuration execution. Legacy text array. |
| `vela_workflows_list` | Fresh workflow summaries without running inputs or steps. Legacy text array. |
| `vela_evals_list` | Recorded evaluation summaries without raw transcripts, output or argv. Legacy text array. |
| `vela_checkpoints_list` | Fresh checkpoint summaries. Legacy text array. |
| `vela_memory_get` | Bounded current memory text; optional candidate review. |
| `vela_library_search` | Current explicitly public Library paragraphs from the local index, preserving index availability and source references. |
| `vela_library_list` / `vela_library_get` | Fresh explicitly public Library summaries/text. |
| `vela_guidelines_list` / `vela_guidelines_read` | Active project Guideline summaries/text. |
| `vela_workflows_read` | Current project Workflow Markdown text. This does not validate or execute its tools. |
| `vela_health` | Local MCP permission mode and project-store read status. Provider/account status is `not_queried`. |

Every call requires an absolute registered `project`. Memory branch/worktree/task/session/namespace scopes require matching query context; default project retrieval never silently includes those scopes. Sources must retain their current visibility and managed-file identity. Missing, linked, malformed, private, archived, cross-project and scope-ineligible assets are withheld. Library requires an explicit public Boolean, with the same checks applied to managed metadata. Source privacy edited only in a managed Markdown header also blocks MCP retrieval.

Metadata-only session/setup/evaluation summaries describe captured observations, not live processes or a new scan. An existing source hash is preserved; an unknown source hash is not fabricated from an empty body.

| `--contribute` tool | Allowed local effect |
| --- | --- |
| `vela_memory_contribute` / `vela_remember` | Create one new candidate memory, with a fresh generated ID. Never overwrite, activate or supersede. |
| `vela_remember_bulk` | Validate 1–20 entries, then atomically create all as candidates. |
| `vela_checkpoint_save` | Save a local checkpoint; capture fixed read-only Git status/branch/HEAD using the existing isolated Git command adapter. |
| `vela_signal_record` | Save candidate evidence tied to a real observed session in this project; a supplied message ID must exist in the observed window. |
| `vela_suggestion_draft` | Save a draft without operations or promotion. |
| `vela_local_archive_restore` | Validate an explicit local Vela archive and import as candidates. No path resolution, account access, remote recovery, decryption or activation. |

Candidate contributions accept the documented memory type and non-global scopes. `sourceMessage` requires a verified `sourceSession`; caller text does not become authenticated observation. Bulk fields cannot select another project. Checkpoint Git observation disables hooks/fsmonitor and user global/system Git configuration; no user test script is executed. Archive import retains Core checksums, deterministic import identities and existing lifecycle decisions; importing the same archive again skips existing entries.

## Paging and source changes

List calls accept `limit` 1–100 (default 20) and an optional `after` scan cursor. Core queries only an ID page first, then refreshes each selected source. `scanned` and `nextCursor` refer to scanned records, including withheld records. An empty visible page may have a continuation; it is not end-of-results. New records inserted before a cursor require a new scan. This is a current-source scan, not a frozen historical list snapshot.

The seven legacy list/search tool text values remain arrays. Their pagination is in:

```json
{
  "_meta": {
    "ai.vela/pagination": {
      "nextCursor": "last-scanned-id-or-kind:id",
      "scanned": 20,
      "omitted": 3,
      "pageLimit": 20,
      "complete": false
    }
  }
}
```

New list tools return `{ "items": [...], "nextCursor": ..., "scanned": ..., "omitted": ..., "pageLimit": ..., "complete": ... }`. Summaries intentionally omit full bodies. Use the matching get/read tool to retrieve text.

Text reads take `id`, `offset` (default 0), `maxCharacters` 1–16,000 (default 4,000) and `sourceHash`. **Offsets and `contentCharacters` count extended grapheme clusters in the fully sanitized visible body**, preserving complete Chinese text, combined marks, flags and emoji. The entire source is sanitized before slicing, so splitting a credential into small pages cannot reconstruct it. `sourceHash` binds the original complete body; every offset after zero requires the same hash. A changed source, missing hash or invalid offset returns a tool error. Start again at zero after inspecting a change. Privacy and source identity are rechecked for every page.

`contentRedacted` indicates that full-source sanitization changed the source. Secret-pattern redaction is conservative and does not claim to recognize every possible sensitive string; project/source privacy remains the access boundary. URLs matching credential patterns are withheld from summaries. Library paragraphs inconsistent with the fully sanitized source are omitted rather than returned as partial credential fragments.

## Migration from the previous Vela tools

The seven read names and four original contribution names remain available. Existing lists retain text-array shape; bodies now have explicit bounded get/read endpoints, and list clients should follow the metadata cursor.

Previously ignored `id`, `path`, `includePrivate`, `supersedes`, activation states and other unsupported fields now fail explicitly. Do not send an old record ID to a create-only contribution. Read/update/activation are separate Vela operations and are not authorized by MCP contribute mode. Safe legacy Title Case memory type/scope values such as `Fact` and `Project`, and `Candidate`, are explicitly listed in the schema and normalized to lowercase. `Active` remains rejected for contribution.

## Validation and remaining coverage

- `Tests/VelaCoreTests/MCPToolsTests.swift`: lifecycle, version/catalog compatibility, types/ranges, registered/cross-project scope, private scan progress, grapheme/hash pages, managed-source revocation, candidate atomicity and local Core dispatch.
- `Tests/VelaCoreTests/MCPReviewTests.swift`: independently reproduced full-source credential pagination and URL-metadata regressions.
- `scripts/test-mcp-stdio.py --output <new-receipt.json>`: frozen-helper real stdio consumer across all four supported versions, isolated synthetic sources and zero provider calls.
- `scripts/test-rpc.py`: existing JSONL/MCP compatibility regression.

Actual receipts are kept separately under `output/parity`; a successful portable run is not presented as XCTest. This surface does not close remote `remember/recall/analyze/restore`, HTTP/OAuth, model-powered Brain Ask over MCP, or every reference product integration.

## 中文摘要

默认 stdio MCP 只读取已注册项目中当前、公开且 scope 合格的数据；显式 `--contribute` 只增加候选记忆与少量本地记录。旧合法工具名称、数组文本结果与安全 Title Case 参数保留；过去被静默删掉的危险/未知字段现在明确拒绝。分页按扫描身份推进，正文先完整脱敏再按可见字符分页，后续页要求原文 hash 不变。没有模型、工作流执行、任意文件操作或远端账户权限；远端 MCP/HTTP/OAuth 等仍单独列为待完成范围。
