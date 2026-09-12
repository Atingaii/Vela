# Contributing to Vela

Vela is an open-source developer preview. Focused changes with reproducible evidence are welcome. Read [the current boundaries](docs/status.md) before proposing work from the broader [requirements](docs/requirements.md).

## Development setup

Use an Apple Silicon Mac running macOS 13 or newer, Git, and Swift 5.9 or newer. Xcode Command Line Tools are sufficient to build the app. A **complete Xcode installation is required for `swift test` and XCTest**.

Python 3 runs packaging and integration scripts. Node.js 22+ runs repository JavaScript checks. Neither runtime is required by the installed application.

```sh
git clone https://github.com/Atingaii/Vela.git
cd Vela
swift build
swift run VelaDesktop
```

`VelaDesktop` is the GUI SwiftPM product, `vela` is the CLI, and `Vela.app` is the packaged app. Use a disposable store during development, and disable provider discovery when testing unrelated features:

```sh
VELA_HOME=/absolute/path/to/disposable-vela-store \
VELA_DISABLE_DISCOVERY=1 swift run vela doctor
```

Use synthetic, sanitized fixtures for parsers and workflows. Do not commit real conversations, provider databases, access tokens, personal paths or user configuration. Only remove temporary directories that your task created.

## Validation

With complete Xcode selected:

```sh
swift test
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

With Command Line Tools only:

```sh
swift build
python3 scripts/test-portable.py
python3 scripts/test-rpc.py
python3 scripts/check-repository.py
```

The portable runner compiles the real core and the same synchronous test bodies with an assertion compatibility layer. It is not XCTest, and cannot stand in for every capability of that framework. Report which runner you used; do not label a portable run as a successful `swift test` run. The macOS CI configuration uses full-Xcode XCTest.

The RPC script exercises the built `vela` executable through JSONL and MCP with disposable stores. Repository checks validate JavaScript syntax, static references and packaging hygiene inputs. They do not replace browser interaction checks or native app testing.

For changes affecting distribution:

```sh
bash scripts/package-macos.sh
open releases/Vela.app
```

Inspect the bundle and release audit, then verify the actual packaged app. The default developer package is ad-hoc signed. Developer ID signing and Apple notarization require the maintainer's own credentials and explicit release configuration; a successful local build does not provide either.

## Pull requests

1. Discuss changes to product scope, public APIs, storage formats or major dependencies in an issue. A focused bug fix can go directly to a pull request.
2. Explain the user-visible problem, resulting behavior and relevant limits. Keep the scope narrow.
3. Add meaningful tests for privacy boundaries, filesystem writes, parser offsets, process execution, scheduling and approvals. Test real files and SQLite; do not replace the backend with fixtures that merely reproduce the implementation.
4. Run the applicable checks above. For interface changes, verify loading, empty and failure states as well as the successful path.
5. Update documentation and the changelog. Record a new ADR when a lasting engineering boundary changes.

Use a clear commit subject, for example `fix: preserve partial JSONL records during ingestion`. No particular commit-signing identity is required for a contribution.

## Interface implementation provenance

The initial desktop interface and website were authored through Antigravity CLI `gemini-3.8-flash-high`, as requested by the project initiator. Current project UI and styling work follows that workflow and records its tool/model provenance. Core, security, integration and documentation work does not require that model. Keep public release materials free of private tool transcripts and credentials.

## Review principles

- Report actual evidence, missing data and adapter limitations. A visible screen is not proof that its feature is implemented.
- Preserve project isolation and private retrieval boundaries in the backend.
- Freeze execution arguments before approval, claim actions atomically across processes, and do not treat a test script as an inherently read-only operation.
- Keep rule-based drafting, recorded snapshots and command comparisons distinct from model planning, effective prompt injection and complete agent evaluation.
- Distinguish performance targets from measurements, including the tested workload and process boundary.
- Do not copy private source, prompts or brand assets from reference products.

Report security issues through [private vulnerability reporting](https://github.com/Atingaii/Vela/security/advisories/new), following [SECURITY.md](SECURITY.md), rather than a public issue.
