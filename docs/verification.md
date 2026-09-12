# Verification record

Release candidate: `0.1.0-preview.1`, 12 September 2026.

This record separates executed checks from targets. Synthetic fixtures contain no user sessions or credentials.

## Functional checks

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
