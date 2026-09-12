# Changelog

Changes are documented by user-visible behavior. Preview storage formats may change before a stable compatibility policy is declared.

## 0.1.0-preview.2 — 2026-09-12

A product experience update to the macOS workspace and public website. The underlying preview boundaries remain documented in [feature status](docs/status.md).

### Changed

- Organize the desktop around sessions, workflows and approvals, with project Memory directly available in the sidebar. Keep shortcuts available through native menus and tooltips.
- Prioritize task content in four-column session lists and session details; disclose technical metadata on demand.
- Correct Setup asset categories, distinguish empty filter results from missing logs, and preserve form drafts during automatic data refreshes.
- Redesign the public website around a light grid, large Space Grotesk headings, self-hosted fonts and actual desktop screenshots, with a dark theme and responsive navigation.

### Added

- Original Vela application icon and three compact, generated notification sounds, with reproducible source assets and packaging validation.
- Separate approval, completion, error and sound preferences. Notifications establish a silent history baseline, coalesce repeated transitions and link to the relevant project and record.
- Real-CLI browser interaction checks backed by an isolated synthetic project, plus notification-policy and preference-validation tests.
- Actual macOS screenshots in both READMEs and explicit image provenance.

## 0.1.0-preview.1 — 2026-09-12

First developer preview of the local macOS engineering workspace. This release covers implemented core paths and explicit experimental boundaries; it does not complete the product roadmap.

### Added

- Native macOS desktop shell and a separate `vela` helper, with Agents, Workflows, Setup, Usage, Improve and Lab views.
- Bounded Claude Code/Codex session ingestion, FSEvents updates, retained source evidence, inferred activity states and selected Cursor import formats.
- SQLite WAL persistence and readable Markdown assets; scoped memory lifecycle, active-only recall, conservative budgets and provider-neutral Git checkpoints.
- Setup inventory with sensitive configuration redaction and deterministic diagnostics; private-by-default Library import for text, HTML, PDF, DOCX and explicit document URLs.
- Read-only MCP context tools and opt-in candidate contributions, without agent access to workflow execution or suggestion application.
- Markdown workflows, supported read tools, Dry Run, frozen approvals, cross-process action claims and persisted run records.
- Deterministic correction-based suggestions, reviewable file changes, guarded Apply/Undo and isolated baseline/candidate command comparisons.
- Static product website, source/build documentation, macOS packaging audit and checksum generation.
- Real-core filesystem, SQLite and process tests; a portable runner for Command Line Tools-only development, plus JSONL/MCP black-box checks.

### Preview boundaries

- Apple Silicon and macOS 13+ only. The developer app is ad-hoc signed, without Developer ID signing or Apple notarization.
- Ingestion is bounded; complete history backfill, native session transfer and comprehensive Cursor compatibility are not included.
- Workflow drafting and Improve use deterministic local rules. Guideline versions are captured in run snapshots but are not injected into agent prompts.
- Lab compares actual paired commands; it does not provide a complete agent benchmark or establish token savings and task-quality gains.
- Provider subscription quota, pricing, reset detection and `usage_reset` scheduling are unavailable. Scheduled work requires the app/helper to remain running and does not catch up missed runs.
- A complete Xcode installation is required for `swift test`. Local Command Line Tools validation used the portable runner: 38/38 real-core test methods passed. RPC/MCP black-box checks also passed; portable execution is not XCTest.

See [feature status and limitations](docs/status.md) for details and the [preview release page](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.1) for distribution artifacts.
