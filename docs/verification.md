# Verification record

Current development evidence: 13 September 2026. Released baseline: `0.1.0-preview.2`, 12 September 2026.

This record separates executed checks from targets. Synthetic fixtures contain no user sessions or credentials.

## Website expansion and desktop localization — 13 September 2026

The website's independent navigation, use-case catalogue, four detail pages and sourced comparison are publicly deployed. All ten routes passed checks at 320, 390, 768 and 1280 pixels. Filters, detail navigation, expandable definitions, theme persistence and keyboard/mobile controls were exercised. The final privacy-only correction was rechecked locally and after publication. [Website evidence](evidence/2026-09-13-website-expansion.json) identifies the exact saved source and version; [visual QA](../website/design-qa-expansion.md) records the initial defects and matched reference captures.

The README banner is original vector artwork, separately captioned from actual native screenshots. Six English/Chinese, light/dark and wide/narrow GitHub Markdown render checks passed. [Brand provenance](assets/README-brand-provenance.md) records authorship, asset hashes and the boundaries of the local rendering check.

The current unchanged Core passed **99/99 methods** using the portable runner, including four new localization cases. Real RPC/MCP, bounded-input, restart and audio-resource checks also passed. [Core evidence](evidence/2026-09-13-localization-core.json) records source hashes, command results and the distinction from XCTest. This local Command Line Tools environment cannot run XCTest.

The final renderer passed **24/24 checks** against the real helper: twelve regression scenarios, six acceptance flows and six localization groups. The language suite includes nine routes, eight principal dialogs, 1,128 matching bilingual keys, no missing keys or page errors, quoted/markup titles without injected nodes, and existing Session accessibility/help text switching without replacing its DOM nodes. All three suites recorded unchanged final UI hashes. [Renderer evidence](evidence/2026-09-13-localization-ui.json) preserves the exact scope and the initial failures that led to the fixes.

Actual AppKit/WKWebView checks used an isolated development wrapper launched through LaunchServices. Native menus changed language; an unsaved Memory title retained focus and the exact selected substring; the 900px and 1250px windows remained usable; source text and argv were unchanged; and English persisted after normal quit/relaunch. Stopping and then terminating only the fixture's own helper during a pending native language save produced one localized alert and retained English. The full native checks used the preceding renderer checkpoint with identical native code. After the final Session accessibility-only patch, the same native menu round trip confirmed that existing row/button labels and status help update; the branch span's title is covered by browser DOM assertions because this macOS accessibility tree does not expose it. [Native evidence](evidence/2026-09-13-localization-native.json) separates these checkpoints and observations.

One first window observation following fault recovery was white and omitted WebContent before app readiness had been independently confirmed. Its exact capture time is unavailable. A later same-launch WK capture was complete; View → Sessions restored native accessibility, and subsequent normal/final launches first showed the complete interface. This remains an initial-display observation with unknown cause, not a resolved defect or an established startup failure rate. The development wrapper does not establish production first-launch reliability or OS notification delivery.

The rebuilt Apple Silicon development archive is **1,453,375 bytes**, SHA-256 `b00283fde80d30c1cc8138c794465bc00728a48b1aaf750286ae481cbe244167`. [Package evidence](evidence/2026-09-13-localization-package.json) verifies strict ad-hoc signatures, the resource allowlist, exact source/package UI bytes including `i18n.js`, the icon, three WAV files and ZIP CRC. The installed app adds no translation service, framework or runtime process. It remains unsigned by Developer ID and unnotarized, and is not a new public GitHub release.

These website and localization changes do not rerun or pass the overall product Golden Scenario. The earlier No-Go decision and model-comparison limitations remain as recorded below. The public macOS download is still preview.2.

## Unreleased acceptance redesign — 13 September 2026

The development branch remains **No-Go / Not Scored** under the [new acceptance framework](ACCEPTANCE.md). This section records incremental evidence, separately from the released preview.2 below.

- **95/95 real-core methods passed** the current portable runner, including strict correction/procedure detection, scope/provenance, create-only private Library assets, symlink boundaries, guarded writes, protected independent Agent Lab verification, old-result reanalysis, rejected promotion, provider-aware reuse, nullable/overflowing usage and two new Reuse preview regressions. The runner is not XCTest. The earlier hosted [macOS CI checkpoint](https://github.com/Atingaii/Vela/actions/runs/34705822040) passed **93 XCTest cases**, integration checks and packaging at commit `8929967`; it does not cover the two later tests or final UI. The first hosted run exposed an expected-error test-helper difference and is retained in [CI evidence](evidence/2026-09-13-ci-core.json).
- Debug Swift build, repository checks, release-audio resource checks and real RPC/MCP integration passed. [Two forced helper restarts](evidence/2026-09-13-restart.json) preserved confirmed Memory/settings/assets and completed a partial UTF-8 log exactly once; this does not simulate power loss or unconfirmed writes. The bounded-input suite rejected a frame above 2 MB before its newline, drained 64 MiB without accumulating it, and accepted the next valid frame in the same process. These are fixture-level observations, not an unrestricted memory guarantee.
- Six **real Codex** turns used the same committed Python task and explicit model request, with three runs per variant. All independently verified and all ran tests. The result is **inconclusive** and promotion was actually refused. An earlier scorer missed compound test commands and incorrectly reported improvement; [the public record](evidence/2026-09-13-agent-lab.json) retains that error, its correction, raw-output hashes and limits. No longitudinal correction reduction was measured.
- The current search index passed 10k/100k records × six query classes, 50 measured samples each: 100k p95 **57.127–77.873 ms**, below the 120 ms limit in this fixture. [Search evidence](evidence/2026-09-13-performance-search.json) preserves environment, binary identity and samples. The historical 132.33 ms failure remains below.
- Nine ingestion scenarios × three samples cover 10/100/1,000 source files, 1/10/50/500 MB logs and 10k/100k raw messages. [Ingestion evidence](evidence/2026-09-13-performance-ingest.json) explicitly separates input from retained data: the 60-file selection and tail limits remain. This does not establish full-history ingestion, cold-start distributions or event-to-UI latency.
- [Usage RPC evidence](evidence/2026-09-13-usage-integrity.json) includes six actual missing/zero/partial/extreme-integer scenarios. Both previously reproduced helper crashes were corrected; each malformed input was followed by a successful request in the same process. Missing values remain null.

The final source commit `91d34e2` passed [hosted macOS CI](https://github.com/Atingaii/Vela/actions/runs/34709059008): **95 XCTest cases with zero failures**, both renderer suites (**12 + 6 checks**), repository/RPC/MCP/bounded-input/restart checks and packaging. [Final CI evidence](evidence/2026-09-13-ci-final.json) records the exact commit and job; the earlier 93-test checkpoint above remains historical.

Hook installation and context-output tests do not establish real provider trust, agent adoption or the full 20-step Golden Scenario. Developer ID/notarization, macOS 13 installation, OS notification delivery and the remaining hard-gate matrix are still required.

### Final renderer, native and package checks

Both complete renderer suites passed on the final UI bytes, including `app.js` SHA-256 `01104e7fbeef5c24a08af20fe70bd1934dc82f1446f7e16e230b03688ee3af0b`. The 12-scenario regression suite initially passed 10/12: a selector needed adjustment for grouped cards, and a real modal autofocus race moved rapid input into the title. The corrected full run passed 12/12; failure and intermediate records are retained. [UI evidence](evidence/2026-09-13-ui.json) joins these results to the six acceptance checks below.

The actual AppKit/WKWebView development wrapper was launched through LaunchServices with a fixed synthetic environment. A 1250 × 800 window used the split inspector; a 900 × 623 window exposed the drawer controls, and Escape closed it. The README's [workspace image](assets/vela-workspace.png) is an unedited capture of this final UI. A first wrapper blocked while opening its fixture marker under Desktop; moving only the test fixture to the OS temporary directory allowed standard launch and interaction. No production host code or OS permission was changed for this observation.

Native Reuse testing independently checked persisted data: preview left the Hook file absent, explicit Apply wrote the exact frozen bytes, reopening the applied record returned its committed Diff, and Undo restored the original file absence. This used synthetic sessions and did not execute or trust a provider Hook. The detailed local record is `output/playwright/native-final-acceptance/reuse-persistence.json`.

The final local development archive passed [package audit](evidence/2026-09-13-package.json): strict ad-hoc signatures, the 12-file resource allowlist, source/package UI byte equality, three WAV files, icon, arm64 executables, ZIP CRC and checksums. The ZIP is **1,370,679 bytes**, SHA-256 `314187788e9bb8a858469bafdcae0071312cbf349c9db89f44b15575ac5adf7e`. There is no Developer ID, Team ID, hardened runtime or notarization ticket. The original production bundle identity was not launched in this final audit; native interaction used the isolated development wrapper. This archive is a local deliverable, not a new public release. Existing public download links still point to preview.2.

After verification, the task's harness/helper and browser sessions were closed. Thirteen explicitly inventoried temporary fixture, debug-wrapper and experiment directories (14,516,944 bytes) were removed after preserving and hash-checking eight original Agent JSON artifacts and 28 supporting diagnostics. Antigravity's task-only briefs, snapshots and temporary workspace permission were also removed. Raw results, failed runs, final images and local delivery archives remain; reusable dependencies, pre-existing build caches and user data were retained. The local cleanup manifest is `output/playwright/acceptance-cleanup.json`.

### Six renderer-to-CLI acceptance checks

At **2026-09-12 17:37:16 UTC** (13 September locally), [test-acceptance-browser.py](../scripts/test-acceptance-browser.py) passed **6/6 checks** in one fresh Harbor/Beacon synthetic fixture on macOS 26.5.1 arm64, using Playwright **1.62.1** and installed Chrome **153**. The renderer called the compiled CLI: **56 Core RPC requests, no Core errors**. The report records `completeSuite: true`, unchanged UI source hashes, and `fullGoldenScenarioPassed: false`.

| Check | Observed result |
| --- | --- |
| Memory lifecycle | All five filters matched persisted records; UI activation changed the selected Candidate to Active. |
| Exact source | A Memory source opened and highlighted its exact indexed Session/Message ID. |
| Cross-project source | Two Codex records shared a native provider Session ID; navigation selected Beacon and its exact message without displaying Harbor content. |
| Lab frozen approval | A real Suggestion's Test form created a linked pending evaluation, freezing Candidate Memory content, baseline context, task, verifier/output files and exact argv including empty/space/quote arguments. The harness refused Agent approval before forwarding it to Core. |
| Reuse Apply/Undo | Preview did not write; explicit Apply preserved the original Stop hook; repeated installed preview offered no redundant Apply; reopening the applied record showed its Diff and outstanding provider trust; Undo restored the exact original bytes. No hook ran. |
| Missing usage | One session without usage displayed unavailable, including the provider/day view. Appending an explicit zero-usage event to the same synthetic source changed the total to a real zero without creating a second session. |

The final run used helper SHA-256 `bbeb97c8da8d28af25d04c532cb461d53c4c8604d0854701d6c9286e14d24483` and `app.js` SHA-256 `01104e7fbeef5c24a08af20fe70bd1934dc82f1446f7e16e230b03688ee3af0b`. Local developer evidence is retained in `output/playwright/acceptance-flow-final/`: `results.json`, `harness-rpc.jsonl`, six scenario PNG/AX captures, and separate missing-usage/applied-untrusted screenshots. These local files contain fixture paths and are not packaged or claimed as public release assets. Browser/helper processes and the generated fixture were removed; reusable Playwright dependencies were retained.

The earlier **17:27:33 UTC** six-check pass remains in `output/playwright/acceptance-flow-qa/`, with `app.js` SHA-256 `7c87b8c16b518895e98b24a8ff5b7cbc6d72aedf60328427e1872d94bd85328d`. A subsequent one-line Reuse dialog copy change removed the internal RPC method name. The final run above repeated all six checks on a new fixture with the updated UI and unchanged helper; the intermediate result was not overwritten.

The preceding Reuse diagnosis exposed two real integration defects: an already-installed draft with no operations failed preview with `Apply requires 1–32 operations`; reopening an applied draft failed with `Base hash mismatch`, preventing access to Undo. The fix permits a no-op preview only for the generated Vela hook at the exact project path with an unchanged observed hash. Applied previews return the same-project committed journal's before/after snapshot. **Apply still rejects empty operations, and Undo still checks the current file against the journal's after-hash.** Two real-file regressions cover unchanged bytes, arbitrary/stale no-op rejection and edited-file Undo refusal. Failure evidence and the resolution are retained in the local `acceptance-flow-reuse-diagnostic-2` evidence directory; its disposable fixture was removed after the final pass.

To reproduce, follow the pinned dependency setup in the script's help, then run `python3 scripts/test-acceptance-browser.py`. Omit `--browser-executable` to use Playwright's installed Chromium; this local run explicitly selected installed Chrome. The test-only native bridge does not verify OS integration, real provider execution, Codex trust or agent adoption. These six component flows do not replace the 20-step Golden Scenario or the separate 12-scenario renderer regression suite.

## Preview.2 verification

Checks executed against the redesigned client and current core:

- **54/54 real-core test methods passed** with the portable runner: the previous 38, nine notification/preferences cases, and seven additional cases for fast new runs, trustworthy session timestamps, history suppression and aggregate routing metadata. This is not XCTest.
- Debug and production Swift builds passed. The production configuration defines `VELA_PACKAGED`; release audit now rejects development-capture markers and the build checkout path in shipped executables.
- JSONL RPC/MCP integration and notification resource validation passed against the current core. Named sounds contain 84,804 bytes in total, use 44.1 kHz 16-bit mono PCM and require no additional audio process.
- The actual AppKit/WKWebView app was used with a separate Harbor store. Session table rows and title controls were exposed to native accessibility; selecting a session showed readable messages in the wide inspector without unnecessary table scrollbars.
- Saving a message through the native interface created a real candidate Memory. A separate CLI read confirmed the exact `sourceSession` and `sourceMessage`; a successful toast alone was not the persistence assertion.
- Native Setup checks showed real Rules, Skills and Hook assets. The Hook preview retained both synthetic environment values as `[REDACTED]`.
- **12/12 final real-CLI renderer scenarios passed** in a fresh two-project fixture using the direct Playwright library and installed Chrome. Coverage includes filtering/keyboard access, all Setup categories, Memory creation/activation/recall, write-free Dry Run followed by approved file writing, exact pending command arguments, settings draft/focus preservation across actual FSEvents, delayed navigation, same-second live transcript additions with scroll preservation, and single/aggregate/failure/removed-project notification routes. See [the full scenario record](implementation/ux-review.md). Native delivery is not simulated by these routing checks.
- Native navigation was checked with paired DOM/computed-style metadata and actual WebKit PNGs. Removing the nonessential sidebar background transition resolved the observed stale highlight. The 1250 × 800 split view and 900 × 620 drawer both expose their key controls; Escape closes the narrow drawer.
- All three Settings sound previews returned successful `NSSound.play()` responses in the native app. A separate CLI read confirmed that notification preferences and `updatedAt` did not change. This verifies playback initiation, not a subjective listening assessment.
- The final ad-hoc application passed strict signature verification, the resource allowlist and development-hook/path exclusion audit. Its UI files match source byte-for-byte. The arm64 ZIP is 1,186,764 bytes; the generated `SHA256SUMS` is the authority for the downloadable archive.
- The final packaged app was relaunched through LaunchServices with the isolated store and loaded all five sessions. Native approval testing verified the file was absent before approval, then matched the exact frozen content afterwards; a separate packaged-CLI read confirmed the run was `completed`.
- The four-page website passed nine categories of browser checks, all 144 local references, four viewport widths (320/390/768/1440), keyboard navigation, theme persistence, reduced motion, contrast and both native product images. Desktop light/dark and mobile light screenshots were reviewed alongside matching px0 references. See [website design QA](../website/design-qa.md).

### Explicit environment limitation

System notification authorization returned `Notifications are not allowed for this application` for both the isolated debug wrapper and the final ad-hoc app launched through LaunchServices. The UI showed the error and the persisted notification setting remained off. OS banner delivery, notification sound delivery and clicking an actual OS notification therefore **did not pass acceptance on this host**. The policy, renderer routing and explicit sound preview checks above are separate evidence. Developer ID signing/notarization and verification on a supported installation remain required; no claim is made that signing alone has been proven to resolve this denial.

The first LaunchServices inspection briefly exposed a loading accessibility tree; a later focused inspection and a separate relaunch loaded the real data without a code change. This was not established as a reproducible application defect or a measured startup-time result.

The macOS CI job runs full XCTest and independently packages the application. Consult the commit’s required CI check and the release notes for the hosted result and publication links.

## Preview.1 baseline checks

The following describes the previous release and provides historical context; it is not a claim that those checks were all rerun for preview.2.



- 38 original core test methods passed with `python3 scripts/test-portable.py`. This runner compiles the actual Swift core and executes the test bodies against temporary files, SQLite, local HTTP, and Git. It is a Command Line Tools fallback, not the XCTest framework.
- Full XCTest is configured in the macOS GitHub Actions job. Consult the CI badge and run history for its result.
- `python3 scripts/test-rpc.py` passed for persistent settings, unsupported-method rejection, private search and memory isolation, mandatory registered MCP project, candidate-only contribution, session-scoped recall, and write-free dry runs.
- The packaged AppKit/WebKit app was launched using a separate synthetic store. Native UI checks confirmed session details, message-to-candidate Memory save, frozen approval execution, and a completed Run Ledger entry with real command output.
- The injected native bridge was exercised in a JavaScript VM for resolution, errors, timeout cleanup, pending-call limits and shutdown rejection. This complements native checks; it does not emulate WebKit.
- Developer ID signing and notarization were not available on the build host. Ad-hoc signature verification and a distributable file allowlist are part of packaging.

## Initial performance measurements

Local arm64 Mac, release build, macOS 26. A small GUI fixture had one project and four sessions. After the app settled, five samples one second apart reported:

| Metric | Observed |
| --- | --- |
| GUI + CLI helper RSS | approximately 102.9 MiB |
| Total RSS including WebKit GPU, Networking and WebContent | 196.6–196.7 MiB |
| Sum of sampled idle CPU percentages | 0.0% at `ps` display precision |

RSS is the sum of process resident sizes, not unique physical memory or an Energy Impact score. A previous partial sample omitted the GPU process and must not be used as a total. These short idle observations are not a stress test or a universal memory guarantee.

`python3 scripts/benchmark-read.py` measured the production CLI's JSONL RPC search against 100,000 synthetic session records, after ten warm-ups and over fifty sequential queries returning fifty matches each:

| Metric | Observed |
| --- | --- |
| Median warm search latency | 122.29 ms |
| p95 warm search latency (nearest rank) | 132.33 ms |
| Maximum warm search latency | 137.39 ms |

This checks SQLite substring search plus RPC serialization. It does not measure cold launch, ingestion throughput, semantic relevance, large transcripts, parallel agents, or long-term memory growth. The benchmark removes its own database on completion.

## Remaining release work

See [functional status](status.md) for unsupported and experimental features. Broader provider-format fixtures, sustained resource profiling, cold-start distributions, signed installer verification, and tests on macOS 13 remain necessary before a stable release. GitHub CI validates the available hosted macOS environment; it is not proof of compatibility with every supported OS version.


## Full capability expansion — 13 September 2026

This is an in-progress development record, not a new release or complete-product acceptance. The target is the [228-item inventory](parity/README.md). The previous 99-XCTest/24-renderer CI result belongs to commit `ea8fbd257f813c604a93e070d5f98a6337829d81`; it does not validate these later uncommitted additions.

The following checks have distinct scopes and helper snapshots. Their counts must not be summed into a final-checkout total:

| Slice | Observed result | Evidence scope |
| --- | --- | --- |
| Pi/OMP source identity and branch ingestion | 16 real-Core fixture methods passed | Version/branch/source identity, bounded streaming and rewrite races; not all historical formats |
| Local TypeScript/Python SDKs | Installed archive: TS 10 tests plus consumer tsc; Python 8 tests | Actual npm tarball/wheel installation with isolated real helper, not source-import-only tests |
| Local semantic memory | 9 Core and 5 compiled-CLI checks passed | Installed Apple English/Chinese models on synthetic content; not longitudinal recall quality |
| ModelImprove protocol | 13 Core methods and 7 CLI checks passed | Frozen evidence and three-phase proposal boundaries; no automatic Apply |
| Live ModelImprove | Three real provider calls completed, zero reported tools, one unapplied Rule draft | Codex 0.154.0, requested gpt-5.6-sol/low; observed model unavailable. Frozen helper SHA-256 `31bc1925225b09d0cf754d578f73972dcd8e9a5de9d1aa3c9ac05c0f484d6439`; synthetic indexed source only |
| Live workflow planning | Real provider produced a disabled unsaved draft, then the fixture explicitly saved it | Codex 0.154.0/gpt-5.6-sol request, 12.168 seconds. Initial helper digest recorded; this earlier attempt did not freeze the binary across every call, so it is not final binary acceptance |
| Live quota | Read-only Codex app-server returned 2 buckets / 3 windows, fresh data | No reset or account mutation; receipt retains counts, version and hash without account identity or quota percentages |
| Daemon lifecycle | Isolated actual launchd install/start/restart after SIGKILL/stop/uninstall passed | Source identity checked; service and fixture cleaned. Slow Git tick SIGTERM completed in 0.412 seconds with child group stopped |
| Optional Walrus adapter | Actual packed SDK install and public unauthenticated compatibility preflight passed | Real official dependency packages and mainnet/testnet version endpoints; not authenticated storage, encryption round trip or an owner transaction |
| Connector rejection | Actual unauthenticated Composio HTTPS request rejected its synthetic invalid key; local profile stayed unconfigured | No Keychain write, account connection or external tool action. Temporary helper/store deleted |

Reproduction entry points are `scripts/test-provider-rpc.py`, `test-quota-rpc.py`, `test-sdks.py`, `test-semantic-rpc.py`, `test-model-improvement-rpc.py`, `verify-model-improvement-live.py`, `test-workflow-planner-live.py`, `test-daemon-shutdown.py`, `test-launchd.py`, and `test-walrus-sdk.py`. Read each script's explicit live opt-in and fixture requirements before running it. Live model/provider checks are separate from default offline regression.

Detailed local receipts and failed-before/fixed-after logs are retained under ignored `output/parity/`; reusable dependencies are retained, disposable fixture stores are removed. The implementation contracts and ADRs record supported behavior and remaining gaps. The first planner attempt failed on Codex's explicit disabled Code Mode diagnostic; the adapter only recognizes that exact diagnostic with strict shape, retaining all other tool/error rejection. This does not relax the no-tools proposal contract.

Independent review exposed schedule claim recovery, completion journal UPSERT interaction, connector partial-effect failure and credential-echo handling, and workflow output recovery defects. Reproductions are kept and fixes require their own regression results. UI, final full-Core/CI, native controls, packaging, real external accounts and the complete Golden Scenario remain separate acceptance work; none is inferred from a local test count.

### Later development slices on the same date

The [public evidence summary](parity/development-evidence-2026-09-13.json) preserves selected receipt fields and the original receipt digests. Raw local evidence remains under ignored `output/parity/` and `output/playwright/`. These results have different frozen sources and must not be combined into one final-checkout test count.

- Library now has versioned updates, recoverable archives, source refresh, Markdown export and explicit paragraph FTS5 indexing. Real document checks include DOC, DOCX, ODT, RTF, HTML, text PDF and plain-text formats. Independent tests first reproduced malformed/missing privacy flags and missing managed assets reaching retrieval; the common fresh-source gate fixed those cases. The later 10-method state/freshness group includes seven paragraph retrieval cases, two runtime-summary cases and the independent Watch revocation case (`independent-state-freshness-round2.json`).
- A real Codex 0.154.0 knowledge answer completed one approved call in **10.987 seconds**, with two exact-source citations and zero reported tools. Requested model/effort were `gpt-5.6-sol`/`low`; actual model identity was not exposed. Exact quotation validation is distinct from semantic correctness. The frozen helper digest is in the public summary. This was the lexical retrieval path, not a live FTS or quality benchmark.
- A separate real Codex loop completed **two model calls and one actual Git status read** in **17.967 seconds**. A random fixture filename visible only in the Git result appeared in the next prompt and final answer; fixture bytes remained unchanged. This proves that actual read results reached the following model round, not that external connectors or every provider are validated.
- A barrier-controlled local provider initially exposed blocked progress/cancellation on one RPC connection. After separate control admission and instance locking, both ordinary-load and 32-request saturation checks returned get/cancel before releasing the provider; one synthetic invocation, zero tool receipts and a cancelled loop were recorded. The later list-state regression also showed that rejected approvals must override stale raw `pending_approval` records. Lists now join narrow approval metadata without deserializing provider transcripts.
- Installed optional packages passed **TypeScript 12**, **Python 10**, **Walrus adapter 25**, and **OpenClaw 6** checks. OpenClaw 2026.9.4 additionally ran a complete actual host turn against a deterministic loopback provider: same-namespace injection, a real `memory_store` call, and `agent_end` created two candidate records. Neither became Active. This exposed and fixed the plugin manifest's missing tool contract, which isolated hook tests had missed. There was no real model or remote encrypted storage call in this host test.
- Frozen UI round 4 passed five new capability flows and the subsequent locale suite passed six checks. A later frozen round 5b passed seven additional real-helper flows: observed Setup diff, stale workflow review and cloning, archive/restore/validation, no-source Ask, approved synthetic-provider answer and citations, separately approved follow-up cancellation, and loop cancellation before execution. Native dialogs remain a test boundary. The initial round 5 failures included harness assumptions about lowercase provider IDs, ID-based validation rows, tokenized search queries and rejected pending approvals; their evidence is retained. A separate source-reference check found five keys absent from both dictionaries, which equal dictionary-size checks had missed; UI remediation is tracked separately.
- Tool Watch and FSEvents file observation have **43** passing methods on their final focused source snapshot. Separate actual daemon fixtures observed a Git change and a filesystem event, created one pending approval each, and did not write or dispatch again after restart. A source revoked during debounce initially escaped the before-only removal check; the independent regression now passes for both item and whole-output modes. These older frozen daemon binaries are not evidence for the final packaged application.
- A frozen production helper on Apple M2 Pro / 32 GiB / macOS 26.5.1 passed six warm substring-search cases each at 10,000 and 100,000 indexed objects. The largest case p95 was **11.512 ms** and **82.370 ms**, respectively, with ten warm-ups and fifty samples per case. This is warm RPC search on synthetic indexed objects, not full historical ingestion, cold launch, RSS, concurrency or current final-package performance.

The expanded CI configuration now includes capability RPC contracts, control saturation, installed SDK/host checks and the new renderer flows. A configuration change is not a hosted CI pass. Sui testnet funding, actual encrypted round-trip/owner operations, successful external connector accounts, current native packaging and the remaining inventory items are still open.

The first complete Core checkpoint after these slices passed **334/334** methods using the portable fallback. Source snapshot `7c9fdc24a87d5f4fe347d3e56ab845ff9e8984458c38d2b36dc6ea691a84e27d` matched the working tree at the end of execution (`output/parity/core-round5-snapshot.json`). This is one complete captured Core/test set, unlike the separate focused counts above; it still does not validate the in-progress UI, the hosted XCTest environment or all 228 capabilities. The same source includes the four JSONL history adapters; their independent CLI check discovered 73 sources and restored 1,202 original records over 20 batches without a provider call.

The same frozen CLI (`d42897eb0c51bbcafa21cec1bc704f7db4abbec1de1d86b3afe83cc81e630dce`) then passed all **14 contract scripts**, including normal and saturated cancellation, lexical and paragraph-FTS Ask, and explicit history import. The helper digest was unchanged throughout; no external provider was called. A subsequent installed Walrus package passed **33 checks** and consumer typechecking after a real HTTP fixture exposed mutable nested arguments in the older 32-check package. Preparation now deep-copies arguments before hashing and saving them: mutating the caller array cannot change the approved network request. The earlier package and failure evidence are retained; current package SHA is `53a90db381c1979943bd8769c0219ddb5ff8d39a9531f59da4a1d22d8523e3b8`.

Independent release review reproduced a non-demo `fixture-data.js` silently entering the bundle through extension-based filtering. Packaging and release audit now share five exact UI resource paths, reject unknown or linked resources, require every named resource, and exclude the explicitly named development demo. Seven resource tests and byte-for-byte copying of actual UI/icon/sound inputs passed. Those tests isolate architecture probing; a real signed-bundle audit is still a separate result.

The installed-consumer review subsequently reproduced two further boundary defects. OpenClaw `captureMaxMessages=1` admitted a second candidate; the fix applies the cap before appending and the new package passed seven checks plus typechecking and the complete actual host/loopback-provider flow. A cancelled Python call waiting behind another operation borrowed that operation’s request ID and uncertainty state; per-call dispatch state now preserves each request’s own recovery metadata. The new Python wheel passed eleven installed tests, including both queued/read-write orderings and an actually dispatched write cancellation. Receipts are separate from the earlier packages; TS and Walrus were unchanged and were not rerun solely to inflate a total.

### Hosted checkpoint correction

[CI run 34742282084](https://github.com/Atingaii/Vela/actions/runs/34742282084) tested immutable commit `b94707ff41620b3928dede2b8eefe49f90f1f64c`. The independently installed SDK/OpenClaw job passed. Actual XCTest executed 334 methods but reported **158 assertion failures**: 157 came from throwing service calls placed inside `XCTUnwrap` autoclosures; the remaining quota-flood classification assertion did not log its observed error kind. Renderer and package steps were skipped after the Core failure. This run is a failure, not a green checkpoint.

The previous portable runner rethrew unwrap failures without recording them. Real [XCTest unwrap semantics](https://github.com/swiftlang/swift-corelibs-xctest/blob/main/Sources/XCTest/Public/XCTAssert.swift) record failure before rethrowing; catching that error in an outer `XCTAssertThrowsError` does not erase it. The runner now records both nil and thrown-expression failures. Twenty-one affected test helpers evaluate service calls before unwrapping optional results, preserving their original business-error assertions. An independent four-case assertion-support check fails with the old runner and passes with the corrected one; a frozen old workflow-planning fixture also reproduces the hosted failures under the corrected runner. No product validation was relaxed. The quota assertion now includes the actual mode/classification; its hosted outcome remains to be established.

The old 334-method portable receipt remains historical evidence of what that runner reported. It must not be generalized to XCTest acceptance. Raw hosted logs, exact helper corrections and before/after assertion receipts remain under `output/parity/ci-checkpoint-b94707f/`.

After the helper corrections, the corrected portable runner passed all **334 methods** against a separate frozen copy of the b94707f Core. Snapshot `cc81f1077fa4d8bf610412d19e3e51d4701d29303fcc7a9f2d96ffdf6519770d` matched that copy at the end. The unchanged quota budget passed locally, but its hosted failure remains separately pending the added diagnostic. This excludes ongoing AI middleware/Plan work and is still not an XCTest result.

The corrected checkpoint `cf00a48` ran [334 actual XCTest methods](https://github.com/Atingaii/Vela/actions/runs/34742860219) with **two assertion failures and no unexpected failures**, both in the filesystem Watch restart case. All nine provider-quota methods passed this time. The separate installed-SDK/OpenClaw job passed again. The failure prevents later renderer and packaging steps from running; neither checkpoint is a complete CI pass. The restart case is being reproduced independently before changing production or test expectations.

Ask consumer UI round 6b passed all three previously failing scenarios against an immutable helper and UI snapshot: frozen input review before approval, preserving a New draft after a delayed real `ask.list` response, and exact branch-scope retention with a new follow-up approval. The first updated-UI run incorrectly rejected a visibly labelled 47-second timeout because it matched template whitespace; the harness now reads that rendered field. The identical corrected harness still fails all three original-UI scenarios. Receipts and before/after screenshots are separate; only a loopback synthetic provider ran, and this is not native or final-checkout acceptance.
