# Desktop product refinement — 2026-09-14

The development UI now uses a quiet sidebar, readable content, task-specific icons and contextual actions. This is a tested interface revision, not a declaration that Vela matches every capability of its three references or is ready for stable release.

## Product decisions and implementation

- Lists prioritize a one-line name, up to two lines of summary, meaningful state and one consistent action menu. Full names remain available in detail and accessible labels; source strings are not shortened in storage.
- Workflows separate definitions, run history and schedules. Plans, artifacts and health stay available through a labeled secondary menu. Running a workflow still uses the existing approval boundary.
- Setup groups assets by known scope and uses file-type icons. Generic `SKILL.md` entries use their actual parent directory name. Credentials, hashes, full paths and other technical fields are disclosed only in details. Unknown scope remains unknown. Memory has one primary destination; the former Setup entry is an explicit menu link.
- Sessions, approvals, Memory and Setup reuse local Marked, DOMPurify and Prism readers. Tool commands have a readable primary view plus the original record. Markdown front matter is a collapsed document-properties section; source and copy preserve the full supplied text. Raw HTML remains inert and does not load external resources.
- Settings separates general preferences, notifications, connections and privacy. Switching sections preserves drafts. Simplified Chinese and English also update native menus.
- Account limits remain separate from indexed log usage. Unavailable values are not zero. A real regression in this revision was corrected: an open disclosure inside a hidden quota pane no longer blocks log-usage updates.

## Implementation provenance

WorkBuddy 5.5.6 with the explicitly selected **Deepseek-V4.1-Flash** produced the initial design pass in an isolated workspace. Its second pass ended with network timeout 3003. Codex reviewed and completed the integration, including scope/name handling, Settings sections, workflow navigation, file readers and the hidden-disclosure fix. No other model is claimed to have completed or approved the final product.

The existing Swift/AppKit/WKWebView/SQLite stack and packaged resource allowlist remain. This pass adds no client network dependency, icon font, continuous animation or new background observer.

## Verification on this Mac

| Surface | Actual result | Evidence |
| --- | --- | --- |
| V3 browser + isolated real helper | Engineering 11/11; localization 6/6; reading 6/6; design 15/15 | [Versioned browser evidence](../evidence/2026-09-14-workbuddy-v3-browser.json) |
| Specific V2 regression | Acceptance 6/6, including unavailable usage becoming a genuinely observed zero | Referenced separately in the browser evidence; not counted as V3 runs |
| Native AppKit/WKWebView | Skill preview/source/copy; exact command copy; Memory-to-source navigation; approve/write; reject; workflow-to-approval; nested Escape; Chinese/English switching | [Native interaction evidence](../evidence/2026-09-14-workbuddy-v3-native.json) |
| Local core boundary | Existing black-box RPC/MCP regression script passed | [Build evidence](../evidence/2026-09-14-workbuddy-v3-package.json) |
| macOS development bundle | Two-job release build, ad-hoc signature verification, resource allowlist and exact V3 UI bytes passed | [Build evidence](../evidence/2026-09-14-workbuddy-v3-package.json) |
| Idle observation | 20 seconds, five samples; directly attributable host/helper averaged 0.9% CPU, maximum combined RSS 113.46 MiB | [Raw scoped observation](../evidence/2026-09-14-workbuddy-v3-idle.json) |

The memory observation excludes WebKit XPC processes whose ownership could not be established through the available process interfaces; it is **not total application memory**. Browser and native fixtures are synthetic projects using the actual local helper, not live provider or remote-account proof. This Command Line Tools environment did not run XCTest. The development app is ad-hoc signed and not Apple-notarized.

The native screenshot set is captured from this V3 UI, without editing the captured pixels. Website and README captions identify the development version and synthetic data. Historical screenshots and failed test receipts remain separate evidence.

## Remaining product acceptance

The [three-reference gap report](../parity/three-reference-delivery-gap-2026-09-14.md) identifies the concrete remaining work and evidence requirements. The [product acceptance decision](../ACCEPTANCE.md) remains No-Go. Neither 38 UI checks nor a successful package closes the 188-item specification or the 228-capability reference ledger.

`scripts/verify-golden-source-chain.py` adds an offline check of source, automatic candidate, approval, Lab and execution receipt relationships. It rejects missing or inconsistent evidence. It cannot authenticate a provider or model behavior; even a self-consistent supplied next-session receipt cannot make the complete Golden scenario pass.
