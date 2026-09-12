<img src="Sources/VelaApp/Resources/Design/app-icon.png" width="80" height="80" alt="Vela app icon">

# Vela

**The engineering layer for coding agents.**

[简体中文](README.zh-CN.md) · [Website](https://vela-engineering.zzzsssaa.chatgpt.site) · [Download preview](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.2) · [Contributing](CONTRIBUTING.md)

[![CI](https://github.com/Atingaii/Vela/actions/workflows/ci.yml/badge.svg)](https://github.com/Atingaii/Vela/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS%2013%2B-black)

An agent session ends. Your engineering context should not.

Vela is a local macOS workspace for supported Claude Code, Codex and Cursor session data. It brings conversation evidence, project memory, reviewable workflows and measured Codex comparisons into one place, alongside the agents you already use.

> **Development branch — acceptance redesign, not yet released.** The download still points to preview.2. The 20-step product scenario and six release gates are **not passed**; see [acceptance](docs/ACCEPTANCE.md), [traceability](docs/TRACEABILITY.md) and the [three-project comparison](docs/reference-comparison.md).

> **0.1.0-preview.2 — developer preview.** The core paths are implemented, with substantial compatibility and automation limits. This is not a complete implementation of the product roadmap or a stable release. The development app is ad-hoc signed, has no Developer ID signature and is not Apple-notarized. Read [feature status and limitations](docs/status.md).

![Vela sessions workspace showing a project and its coding-agent activity](docs/assets/vela-sessions.png)

*Actual macOS application with an isolated example project and synthetic session logs. The interface uses the real local helper and database; no personal session data appears here.*

## What you can use

- **Observe sessions:** browse normalized messages and supported tool events, inspect project setup, and review token counts reported by local logs. Inferred states and incomplete history are labeled.
- **Keep useful context:** save memories with provenance and explicit scope, recall active memories within a conservative budget, and export checkpoints containing user notes and a captured Git state.
- **Review before running:** edit Markdown workflows, dry-run supported reads, approve frozen actions and inspect persisted run records. Project tests and agent commands require approval.
- **Compare actual outcomes:** inspect deterministic correction-based suggestions, preview and safely apply or undo supported file changes, and run baseline/candidate commands in separate Git worktrees at the same commit.
- **Own reference material:** import text, HTML, text-based PDF, DOCX or an explicit document URL. Library imports default to private; private references are excluded from agent search and recall.

Sessions, Memory and Workflows are directly accessible from the sidebar. Project configuration, observed usage, Improve and Lab remain available alongside global Search, Inbox and Settings. Keyboard shortcuts are discoverable in menus and tooltips.

Notifications are optional and off by default. When enabled, Vela groups new approval, completion and error events, links back to the relevant project, and uses three short original sounds. Sound previews are available in Settings. The current ad-hoc build was refused OS notification authorization on the verification host; banner delivery remains unverified. See [verification](docs/verification.md#explicit-environment-limitation).

## Install

Get the Apple Silicon archive and `SHA256SUMS` from the [0.1.0-preview.2 release page](https://github.com/Atingaii/Vela/releases/tag/v0.1.0-preview.2), verify the checksum, then move `Vela.app` into Applications. Minimum supported system: **macOS 13**. Intel builds are not part of this preview.

The development archive is **ad-hoc signed and not notarized**. macOS may require its per-application “Open Anyway” flow after you inspect the source and release. Do not disable Gatekeeper globally. Preview storage formats may change; keep your own backup of important Vela data.

## Build and run

Requirements: an Apple Silicon Mac, Git, and Xcode Command Line Tools with **Swift 5.9+**. The GUI SwiftPM product is `VelaDesktop`; the CLI is `vela`; the packaged application is `Vela.app`.

```sh
git clone https://github.com/Atingaii/Vela.git
cd Vela
swift build
swift run VelaDesktop
```

To package the local application, Python 3 is also required:

```sh
bash scripts/package-macos.sh
open releases/Vela.app
```

The package script defaults to the `dev` channel and produces `releases/Vela-macOS-arm64.zip` and `releases/SHA256SUMS`. Setting a channel does not sign, notarize or publish a release. The installed application uses Swift, AppKit, the system WKWebView, SQLite and other macOS frameworks; it does not require Electron, Node.js or a Python runtime.

## First project and CLI

Add a project directory in the desktop, then inspect Sessions and Setup. Registering a project does not approve executing its scripts. Initial discovery reads a bounded set of recent agent logs; it does not import your entire history.

```sh
swift run vela doctor
swift run vela call projects.add '{"path":"/absolute/path/to/project"}'
swift run vela refresh
swift run vela search 'verification'
swift run vela recall 'project constraints' --project /absolute/path/to/project
```

Use `VELA_HOME` or `--home /absolute/path/to/store` to select a store. The standalone CLI defaults to `~/.vela`. Packaged desktop channels use separate stores; point the CLI and MCP at the desktop store you want to use.

## MCP

Add a stdio MCP server to your agent configuration using the installed helper and your desktop store:

```json
{
  "mcpServers": {
    "vela": {
      "command": "/Applications/Vela.app/Contents/MacOS/vela",
      "args": ["mcp", "--home", "/absolute/path/to/.vela-dev"]
    }
  }
}
```

Read tools expose supported search, recall and context records. Requests require an explicitly selected, registered project. The optional `--contribute` flag also permits candidate memories, checkpoints, session-backed signals and suggestion drafts. Contribution cannot activate an existing memory, apply a suggestion or execute a workflow. Private Library material is excluded from agent retrieval.

## From evidence to reuse

Explicit engineering corrections can create source-linked candidate Memory and reviewable suggestions. Repeated supported tool sequences can propose disabled Workflow drafts. Open the exact source message before choosing what to test.

In Lab, select a committed project, an explicit Codex executable and model, the same task, protected verification files and allowed output files. Review the frozen request in Inbox before running it. A comparison can legitimately be **inconclusive**. Promotion activates only unchanged, tested project Memory after an eligible comparison and explicit review.

To offer active Memory to later Codex sessions, preview and apply the project-only `.codex/hooks.json` change, then review and trust the exact hook in Codex `/hooks`. Vela does not bypass provider trust. Recall receipts establish that context was offered; they do not establish agent compliance or improvement. See the [Lab and Reuse contract](docs/implementation/agent-lab-contract.md).

## Know the preview boundaries

- Initial ingestion selects up to **60 recent source files per provider**, using a **256 KB tail** plus a **32 KB header** where needed. Retained messages are bounded; full historical backfill and native session transfer are not implemented. Cursor compatibility covers exports and selected known SQLite records.
- **Usage is observed log usage.** Subscription quota, reset detection, pricing and the `usage_reset` trigger are unavailable.
- Workflow drafting and Improve use **deterministic local rules**. They are not a general natural-language planner or a model-driven improvement pipeline.
- Guidelines can be saved and frozen in run records, but **are not injected into agent prompts** in this preview.
- Lab supports paired commands and an explicit **Codex agent mode**: frozen task/model request, isolated worktrees, protected verification files, and a separate verifier. Three complete repetitions per variant are required for promotion review. Ties, missing measurements and regressions cannot promote a candidate. The first six real runs were tied; [the evidence](docs/evidence/2026-09-13-agent-lab.json) preserves a corrected scorer defect. Future correction reduction remains unmeasured.
- Scheduled triggers operate while the app/helper is running. There is no always-on system daemon or missed-run catch-up after sleep or shutdown.

See [the detailed status](docs/status.md) for the supported boundaries and [the requirements](docs/requirements.md) for the broader roadmap.

## Validate a checkout

A complete Xcode installation supplies XCTest:

```sh
swift test
```

On a Command Line Tools-only system, build first and use the portable runner:

```sh
swift build
python3 scripts/test-portable.py
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

The portable runner compiles the real core with the same synchronous test bodies and a small assertion compatibility layer. It is **not XCTest**. RPC/MCP tests exercise the compiled CLI with disposable stores. Repository checks require Node.js to validate JavaScript; development tools are not bundled with the app.

For reproducible real-CLI browser interaction checks and synthetic screenshot fixtures, see [Interface checks](CONTRIBUTING.md#interface-checks). Native macOS controls and notifications require a separate app check.

## Data and architecture

Session indexes and run records live in SQLite WAL. Memory, workflow, guideline, library and checkpoint assets also live in readable Markdown under the selected store's `assets/` directory. Vela has no account requirement, hosted memory service or enabled telemetry.

An explicitly imported URL makes a network request. An approved agent command may send the supplied context to its provider. Vela does not automatically submit session history to a model.

The AppKit/WKWebView interface communicates with a separate `vela` helper through restricted JSONL RPC. FSEvents drives incremental ingestion. The website is static HTML, CSS and JavaScript. See [architecture](docs/architecture.md) and [ADR 0001](docs/adr/0001-native-macos-core.md). Performance targets are not presented as measured guarantees.

Executed checks and initial resource/search measurements are recorded in [verification](docs/verification.md).

## Contributing and license

Start with a reproducible problem or a focused improvement. Read [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

Product direction was informed by user-provided Blume analysis, Walrus Memory/MemWal context-ownership ideas and [px0](https://px0.ai/) workflow design. Vela is an independent implementation, unaffiliated with those projects or agent providers. Their private source, prompts and brand assets are not bundled. The initial desktop and website interfaces were authored through the requested Antigravity CLI Gemini 3.8 Flash (High) workflow.

[MIT](LICENSE) © Vela contributors.
