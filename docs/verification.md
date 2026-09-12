# Verification record

Release candidate: `0.1.0-preview.2`, 12 September 2026.

This record separates executed checks from targets. Synthetic fixtures contain no user sessions or credentials.

## Unreleased acceptance redesign — 13 September 2026

The development branch remains **No-Go / Not Scored** under the [new acceptance framework](ACCEPTANCE.md). This section records incremental evidence, separately from the released preview.2 below.

- **93/93 real-core methods passed** the portable runner, including strict correction/procedure detection, scope/provenance, create-only private Library assets, symlink boundaries, guarded writes, protected independent Agent Lab verification, old-result reanalysis, rejected promotion, provider-aware reuse and nullable/overflowing usage. The runner is not XCTest; the hosted [macOS CI checkpoint](https://github.com/Atingaii/Vela/actions/runs/34705822040) also passed all 93 XCTest cases, integration checks and packaging at commit `8929967`. The first hosted run exposed an expected-error test-helper difference and is retained in [CI evidence](evidence/2026-09-13-ci-core.json).
- Debug Swift build, repository checks, release-audio resource checks and real RPC/MCP integration passed. [Two forced helper restarts](evidence/2026-09-13-restart.json) preserved confirmed Memory/settings/assets and completed a partial UTF-8 log exactly once; this does not simulate power loss or unconfirmed writes. The bounded-input suite rejected a frame above 2 MB before its newline, drained 64 MiB without accumulating it, and accepted the next valid frame in the same process. These are fixture-level observations, not an unrestricted memory guarantee.
- Six **real Codex** turns used the same committed Python task and explicit model request, with three runs per variant. All independently verified and all ran tests. The result is **inconclusive** and promotion was actually refused. An earlier scorer missed compound test commands and incorrectly reported improvement; [the public record](evidence/2026-09-13-agent-lab.json) retains that error, its correction, raw-output hashes and limits. No longitudinal correction reduction was measured.
- The current search index passed 10k/100k records × six query classes, 50 measured samples each: 100k p95 **57.127–77.873 ms**, below the 120 ms limit in this fixture. [Search evidence](evidence/2026-09-13-performance-search.json) preserves environment, binary identity and samples. The historical 132.33 ms failure remains below.
- Nine ingestion scenarios × three samples cover 10/100/1,000 source files, 1/10/50/500 MB logs and 10k/100k raw messages. [Ingestion evidence](evidence/2026-09-13-performance-ingest.json) explicitly separates input from retained data: the 60-file selection and tail limits remain. This does not establish full-history ingestion, cold-start distributions or event-to-UI latency.
- [Usage RPC evidence](evidence/2026-09-13-usage-integrity.json) includes six actual missing/zero/partial/extreme-integer scenarios. Both previously reproduced helper crashes were corrected; each malformed input was followed by a successful request in the same process. Missing values remain null.

New renderer/native screenshots, final package matching and hosted CI are recorded only after their corresponding checks finish. Hook installation and context-output tests do not establish real provider trust, agent adoption or the full 20-step Golden Scenario. Developer ID/notarization, macOS 13 installation, OS notification delivery and the remaining hard-gate matrix are still required.

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
