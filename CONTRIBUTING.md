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

## Interface checks

The recommended browser regression runner uses the Playwright library (validated with version 1.62.1), Node.js 22+, Python 3.9+ and an installed Google Chrome. It serves the actual client resources against the compiled local CLI, using an isolated project under `.task-tmp`; it does not load the browser demo. Browser dependencies are development tools and are not bundled with the macOS app.

```sh
npm install --prefix .task-tmp/ui-browser-tools --registry=https://registry.npmjs.org --save-exact playwright@1.62.1
swift build
python3 scripts/create-ui-fixture.py .task-tmp/ui-browser --with-routing-project
python3 scripts/test-ui-browser.py .task-tmp/ui-browser/fixture.json \
  --driver playwright \
  --playwright-module "$PWD/.task-tmp/ui-browser-tools/node_modules/playwright/index.js" \
  --browser-executable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
python3 scripts/test-acceptance-browser.py \
  --browser-executable "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
python3 scripts/test-release-resources.py
```

Use a new fixture directory for each run. The runner closes its browser and helper processes and leaves `browser-results.json` and any failure screenshots in the fixture for inspection. Remove only that disposable directory after review. Native file pickers, menu behavior, notification permission, sound and WebKit-specific rendering still require the actual macOS app.

The additional acceptance runner verifies Memory lifecycle and exact source navigation, cross-project source isolation, frozen Lab approval, Reuse preview/apply/undo, and missing-versus-zero Usage. Its default fixture is `.task-tmp/acceptance-flow-qa`; use `--fixture` for another new path. A successful run removes its marked fixture after preserving the report, screenshots and RPC transcript under `output/playwright/acceptance-flow-qa`; failures retain the fixture for diagnosis. `--checks` runs a diagnostic subset and never reports a complete suite. These checks do not execute a provider task or establish Codex trust or agent adoption.

CI installs the same pinned Playwright package with installation scripts disabled, explicitly installs Chromium under `.task-tmp/ci-browser`, and runs both renderer suites with the real helper. To use that browser locally, set `PLAYWRIGHT_BROWSERS_PATH="$PWD/.task-tmp/ci-browser"`, run `node .task-tmp/ui-browser-tools/node_modules/playwright/cli.js install chromium`, and omit `--browser-executable`. Browser results and failure captures are retained as CI artifacts; real paid Agent Lab experiments remain explicit maintainer runs.

The fixture also supports real-app screenshots. In a non-packaged development build, `VELA_CAPTURE_DIRECTORY` enables a developer capture command only alongside an explicit `VELA_HOME` containing the synthetic fixture marker. Release builds exclude this hook. See [image provenance](docs/assets/README.md) before adding product screenshots.

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
