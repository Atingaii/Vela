# Antigravity UI implementation provenance

## Desktop localization, 2026-09-13

This pass adds the desktop `zh-CN` / `en` preference described in [ADR 0005](../adr/0005-desktop-localization.md). UI and native changes continue to use Antigravity CLI 1.2.2 with `--model gemini-3.8-flash-high --effort high --mode accept-edits --prompt-interactive`. Supervisors implement and review the non-UI preference contract, supply bounded briefs, and verify the resulting sources independently. Historical Preview 2 and Blume refinement results below are not localization acceptance results.

The native author is conversation `68ff7daf-8a4d-41fd-b730-f4abbefec631`, owning `Sources/VelaApp/main.swift` and the new `Localization.swift`. It localized menus, status and notification templates, added the native Language submenu, and synchronized confirmed locale values through existing settings responses without reloading WebKit. Review tightened exact enum handling, response-method provenance, stale-request cleanup and runtime bridge error localization. After the first debug build exposed an unused assignment to a nonexistent `appMenu` member, the same author removed that assignment. A subsequent supervisor-run `swift build` completed successfully; this is a compilation result, not native interaction or notification-delivery proof. The author exited normally after that correction.

The renderer uses the new bundled `Resources/UI/i18n.js`, explicit key bindings and named interpolation. Independent required-model conversations produced bounded fragments for integration by the main renderer author:

| Conversation | Localization scope |
| --- | --- |
| `65173295-9fac-450e-b259-39903230f43e` | Shared renderer runtime and fixed UI bindings, all remaining routes and dialogs, and integration of the independently authored fragments. |
| `3706893e-b4e8-422c-9fad-502cbf46a210` | Lab view, comparison, creation and promotion forms; 243 explicit keys per language. |
| `39084a11-02b5-4569-bad5-01e42c0ab4fe` | Setup, Guidelines, Library and MCP views and dialogs; 127 explicit keys per language. |
| `8cf857f9-0530-473a-8323-d279a60017b6` | Four bounded acceptance corrections: the drawer translator shadow, missing unavailable key, navigation ARIA binding and eight escaped translation-parameter attributes; a later native-driven correction binds existing Session accessibility labels and status/branch tooltips for live switching. |

Both fragment conversations exited normally. The Lab fragment passed six scoped Chromium checks against the actual localization runtime with stubbed RPC, covering existing DOM bindings, draft values/focus/selection, validation and pending-action text, comparison evidence and promotion errors. Those checks did not execute an agent. Both fragment dictionaries passed key and named-parameter parity checks, and their JavaScript passed syntax validation. These fragment checks do not establish production integration or full application acceptance.

The main author integrated the three fragments only after exact comparison with their frozen source ranges. Scoped follow-up edits covered live busy/error/toast state labels, recovery and aggregate-notification surfaces, and nullable statistics. An unused descriptor branch for independent attribute parameters was removed after runtime review exposed a switching defect; explicit attribute bindings retain the shared named-parameter contract. The initial renderer checkpoint contained 1,123 keys per language with matching named placeholders; the bounded acceptance correction brings this to 1,125. Its two JavaScript resources passed syntax validation, and the main author exited normally so independent production-renderer tests could run against frozen source files.

An independent real-RPC localization suite passed all six groups against a fresh synthetic store and the corrected intermediate renderer. It checked strict preference compatibility and persistence, locale-only saves with other settings still unsaved, original Session/Memory content, open routes and details, Workflow draft values and exact argv, focus/selection, and complete browser/helper restart. Nine routes and eight principal dialogs passed fixed-English text and accessibility-attribute coverage; there were no missing keys or page errors. A Memory title containing apostrophes, quotes and literal markup remained identical through the supersede dialog and repeated language switches, produced no injected DOM node, and did not change the stored record. The supersede operation was not submitted. This suite did not execute an agent. Intermediate evidence is retained under `output/playwright/localization-browser-final/`.

The first browser attempt exposed a test-server allowlist omission for `i18n.js`; the harness was corrected and rerun. Subsequent real-renderer failures exposed the local `t` DOM variable shadowing the translator inside `openDrawer`, a missing unavailable key and a fixed navigation ARIA label. A separate review identified eight unescaped JSON parameter attributes, including untrusted Memory titles and project paths. The bounded required-model correction fixed these without changing business operations. Earlier failure evidence is retained rather than overwritten.

The intermediate renderer hashes for that six-group result are `5b747ff7dea15170949d77559d611a5fed03cae26f8f35c2734ff31b63bfe3e8` (`app.js`), `cb3db7d30c18b239c00875d6bfbd9aa94c5b29bc4f89b6a967fcd62cc34373df` (`i18n.js`), and `9fe2ee555b72e4509787def3f63be71f1d3dd1ce9ce9d3c8cb9d821bbc413458` (`index.html`). Syntax and whitespace checks passed. The core portable runner separately passed 99 cases, including the four localization preference tests; this is not a claim that XCTest ran successfully on the local host.

Native inspection then exposed one remaining live-binding omission: already-rendered Session row/button accessibility labels and status/branch tooltips retained their previous language. The same bounded-correction author added explicit attribute bindings and three dictionary keys, retaining raw title, provider, state, source, evidence and branch parameters. The change does not rebuild the list, change its handlers or translate provider values. The author exited normally after the correction, and the final dictionary contains 1,128 keys per language with key parity. Both JavaScript syntax checks and the whitespace check passed.

The final renderer hashes are `403f3c57910a45ca8e2ba56996ab40f71f707d4518ebc956aa0180a76a8d649a` (`app.js`), `028765c6c9d8d49b884528af68e051d585b7448b5963612c9826bb84797054b4` (`i18n.js`), and `9fe2ee555b72e4509787def3f63be71f1d3dd1ce9ce9d3c8cb9d821bbc413458` (`index.html`). A new isolated real-RPC run passed all six localization groups against these exact, unchanged resources. Its live-attribute regression switched existing Session rows from English to Chinese and back without navigation, preserving the same card, button and branch nodes and every original data value. All nine routes and eight principal dialogs passed fixed-English coverage; missing keys and page errors were empty, and all 33 recorded RPC calls completed without error. Evidence, including 22 captures and `session-live-attributes.json`, is retained under `output/playwright/localization-browser-final-ax/`. No agent was executed.

The release owner reran the existing twelve-group renderer regression and six-group feature acceptance suite against the final resource hashes above; all eighteen groups passed with unchanged sources. Together with the six localization groups, this gives 24 passing browser acceptance groups. The final package passed explicit resource-allowlist, embedded UI byte comparison, three sound resources, icon, arm64 binary and ZIP integrity checks. The public result summary is [the localization UI evidence](../evidence/2026-09-13-localization-ui.json); these results are separate from the older Preview 2 and Blume checkpoints.

Native failure feedback received one narrowly scoped correction through the original native author for a helper disconnection during an outstanding Language-menu request. The final native sources are `131d6d05a658bee9a298a91b153dc74f0858e7395a9f61b7b147ab9163ea86e4` (`main.swift`) and `4287c7f87d3a5cd90600ab8cbf56a7be0c8e48ba54995de45b615cc48f8799b7` (`Localization.swift`). The successfully built debug desktop executable, before signing the isolated test wrapper, hashes to `92f4ab618afdb756fabfa0197bc99ff444fecc170bfd0473558e15856bfc3f67`; the real helper hashes to `9bdfad0ea9d20dda7178f76fa7246184cb7d1996f372b921173681e4bbc6565b`.

Actual AppKit/WKWebView checks used an isolated synthetic wrapper launched through LaunchServices. Chinese/English menus and visible pages updated after confirmed persistence. An open Memory draft retained its value, input focus and exact selected range through native-menu language changes; typing afterward replaced only that selection. The reviewed 900- and 1,250-pixel windows kept the Memory dialog and Session inspector readable, and user content and command arguments stayed unchanged. A normal quit and relaunch retained English menus and the initial Sessions page. Stopping then killing only the test helper during a pending native Language request produced one localized failure alert, retained the old confirmed language and did not alter notification, analysis or launch-at-login settings. The stdout-overflow branch was reviewed in source, not fault-injected.

After the final renderer correction, a native English → Chinese → English check on the existing Session list confirmed live row/button accessibility labels and status-source tooltips, preserved raw content and retained correct session opening. The branch tooltip was not exposed by macOS accessibility; its exact live value and original branch parameter are established by the final browser regression and source review, not claimed as a native AX observation. The final native report is retained as `output/playwright/native-language-acceptance/results.json`, alongside the intermediate report, 34 captures and their available metadata.

One first observation after the deliberate helper failure showed a white native window with missing WebContent accessibility. A later snapshot of the same WebKit view was complete, navigation restored accessibility, and a subsequent normal relaunch displayed the complete English page. Its cause remains unknown; no startup fix or broad production-launch guarantee is claimed. These isolated debug-wrapper checks also do not establish system notification authorization, delivery, production signing or notarization. No paid agent experiment ran during localization.

### Localization cleanup

All five desktop author conversations exited normally, including the resumed bounded-correction author. Cleanup removed the twenty explicitly resolved localization scratch files: implementation/review briefs, frozen source snapshots, independently authored fragments and dictionaries, integration notes, and the task-access manifest. The now-empty task directory and the two exact task-created integration scripts in the renderer author's scratch directory were removed. No provider transcript or surrounding provider-history directory was removed.

The supervisor removed exactly its task-added repository `read_file` permission from the latest CLI settings, verifying that all other settings values were unchanged. After every required-model session exited, the native verifier separately removed exactly its task-added repository trust entry from the then-current settings, again verifying that all other values were preserved. The operations were sequential to avoid overwriting concurrent settings changes. The native verifier stopped its app/helper, unregistered only its unique test wrapper and removed its isolated fixture, eleven owned scratch files and the two newly created cache directories belonging to that wrapper's unique bundle identifier. Formal acceptance evidence, product sources, screenshots, release deliverables and reusable dependencies remain intact. No provider transcripts, temporary briefs or credentials are committed.

## Preview 2 authorship context

- Date: 2026-09-12.
- CLI: Antigravity CLI (`agy`) 1.2.2, verified with `agy --version`.
- User-required model: Gemini 3.8 Flash (High).
- Selected model identifier: `gemini-3.8-flash-high`, confirmed by `agy models`.
- Reasoning effort: `high`.
- Execution mode: interactive `accept-edits` with scoped repository access.
- Authorship scope: the AppKit/WebKit host, client HTML/CSS/JavaScript and SVG icon in `Sources/VelaApp/`, plus the four-page static website and its shared CSS/JavaScript. Website staging is handed to the site owner for publication.
- Design reference for the current redesign: the live light theme at [px0.ai](https://px0.ai/), inspected at desktop and mobile sizes. Its paper-white background, fine grid, large Space Grotesk headings, Inter body text and generous spacing inform the website. Vela uses original code, branding, copy and product screenshots. The client follows familiar macOS developer-tool conventions, with grouped navigation and a master/detail workflow.

## Preview 2 redesign

The client redesign uses conversation `286d77dd-5129-47ad-aa7b-d84c0a3f2f37`. The website is implemented independently in conversation `0651ecb8-d293-4c94-844b-b8a0494b9882`. A final native-host-only integration pass uses conversation `fe3747a8-90ee-4247-8986-6051fa761312`, covering notification preview, aggregation routing metadata and the isolated development capture boundary. All three use the same required model and effort. The invocation pattern is:

```sh
agy --conversation <conversation-id> --model gemini-3.8-flash-high --effort high --mode accept-edits --prompt-interactive '<scoped implementation brief>'
```

The client author owns the AppKit/WebKit host, client HTML/CSS/JavaScript, original SVG icon sources and the deterministic notification-sound synthesis source. The website author owns only the public static website. Supervising agents provide product briefs, actual reference and application captures, backend contracts and review findings; they integrate, rasterize approved icon sources, generate WAV resources from the authored synthesis source, package and verify separately. No reference-brand assets or provider conversation logs are part of the deliverable.

The client and website redesign passed their final visual and functional acceptance checks. System notification authorization is tracked separately below; a successful in-app sound preview does not establish operating-system notification delivery.

The release owner compiled the final native-host-only pass successfully with `swift build`. The website verifier completed nine categories of real Chromium checks, 144 local-reference checks and JavaScript syntax validation, recorded in [website design QA](../../website/design-qa.md). Both native product images decode at 1,250 × 800 pixels and preserve their aspect ratio without cropping in the reviewed desktop and mobile layouts; captions identify the synthetic example data. Client integration, native sound playback and notification routing remain separate checks rather than consequences of a successful build.

The session and approval views have been inspected in the actual macOS WebKit host at 1,250 × 800 pixels using an isolated synthetic project. The saved captures are [the session screenshot](../assets/vela-sessions.png) and [the approval screenshot](../assets/vela-approval.png). The final split view keeps all five sample rows visible without unnecessary table scrollbars, preserves the title and status columns, and keeps the inspector actions inside the window. Native accessibility exposes the session rows after restoring table semantics and adding real title buttons. Approval cards expose the frozen file target and a bounded content preview while retaining full parameter and hash disclosure.

A native-only navigation paint discrepancy was diagnosed with development capture metadata: DOM classes and ARIA state were correct while WebKit retained the prior computed background during a short CSS transition. Removing the nonessential sidebar background transition corrected the actual computed styles and captured pixels across consecutive Workflow and Inbox navigation checks. The capture metadata path is development-only, requires the isolated synthetic-store marker, and records navigation state rather than form or conversation content. These checks establish the reviewed native layout and accessibility states; they do not substitute for the functional tests below.

The three original notification sounds are generated by the Antigravity-authored standard-library synthesis source in `Sources/VelaApp/Resources/Design/generate-sounds.py`. A separate verifier confirmed deterministic output, mono 16-bit PCM at 44,100 Hz, and durations of 0.28, 0.32 and 0.36 seconds. The approved SVG app icon was rasterized and converted to the macOS icon format without changing its source design. These transformations are integration steps, not independently authored UI designs.

### Final client acceptance

An independent Playwright runner drove the actual renderer against the compiled `vela` JSON-RPC helper and a fresh isolated synthetic store. All 12 acceptance groups passed. Business methods were real RPC calls; browser tests did not pretend to play native sounds or deliver system notifications.

- Session filtering, clearing filters, accessible title buttons and keyboard opening passed.
- Memory save, activation and project-scoped Recall passed; workflow dry run, frozen approval and a real fixture file write passed.
- Rules, Skills, Hooks and scanned MCP assets were visible; configuration preview retained redaction.
- Unsaved settings retained their draft and focus after a real helper change event and dashboard response, without an automatic-refresh toast or unintended persistence.
- Modal keyboard behavior and rapid navigation with delayed responses passed.
- Notification routes passed cross-project success, read failure followed by navigation without old-scope data, unknown-project fallback and same-project, cross-project and mixed-source aggregation.
- Two log updates within the same second refreshed the live inspector correctly while preserving the reader's scroll position. The cache key uses real lightweight metadata rather than relying only on second-resolution timestamps.
- The approval summary preserved the actual frozen executable and exact JSON arguments, including empty, spaced and quoted arguments. The command fixture remained pending and was not executed.

Separate native checks passed at 1,250 × 800 and 900 × 620 pixels. The narrow window switched to the drawer layout with visible actions and working Escape behavior. Each of the three sound preview controls successfully invoked native playback while the notification master setting remained false and its persisted update timestamp remained unchanged.

The final ad-hoc-signed release opened through LaunchServices and displayed all five fixture sessions in the ready state. The release owner opened a session inspector and approved a real `file.write`: the target was absent before approval, the exact frozen content appeared afterward, and `runs.get` reported completion. An earlier waiting-state observation did not reproduce on the final relaunch and did not justify an initialization change.

Both the development wrapper and final ad-hoc-signed release returned “Notifications are not allowed for this application” during operating-system authorization checks. System notification permission, delivery and notification-center click behavior therefore remain unverified in this environment. In-app sound preview and independently tested routing/policy behavior do not establish those operating-system guarantees.

### Redesign cleanup

All three Antigravity conversations exited normally. Removed seven disposable client implementation/review briefs, the local initial-invocation log and the temporary-permission manifest. The five exact task-added read permissions were reconciled against the final CLI settings: one remained and was removed; the other four were already absent. Removed only this task's workspace-trust entry, preserving all other settings, pre-existing trust, provider history and credentials. Product sources, final screenshots, reusable dependencies and release deliverables remain intact; the release owner handles shared fixture, packaging and capture scratch files separately.

## Blume-inspired client refinement (2026-09-12–13)

This later client refinement uses screenshots of the actual [Blume client](https://blume.codes/) as a design reference. It retains Vela's existing Swift/AppKit/WebKit stack and all eight navigation areas. Warm neutral surfaces, compact status-grouped session lists, restrained blue selection, Memory lifecycle filters and evidence-first Improve cards replace the sparse table presentation. Reference branding, illustrations and proprietary assets are not copied. The website retains the separately reviewed px0-inspired direction.

All client UI implementation continues to use Antigravity CLI 1.2.2 with `--model gemini-3.8-flash-high --effort high --mode accept-edits --prompt-interactive`. The initial invocation requested continuation of the earlier client conversation `286d77dd-5129-47ad-aa7b-d84c0a3f2f37`; its actual exit/resume identifier for this refinement was `ed0f5097-7f11-4dda-b4e7-9f55086bd4ca`. The remaining work is divided into narrowly scoped conversations using that same exact model and effort:

| Conversation | Authorship scope |
| --- | --- |
| `ed0f5097-7f11-4dda-b4e7-9f55086bd4ca` | Client shell, grouped Sessions, Memory lifecycle and exact evidence navigation, Improve and Agent Lab implementation. |
| `fe9a7c9c-96a2-4f39-94da-beca257f650b` | Final modal/drawer/search focus correction, explicit Lab project choice, generic executable placeholder, Usage fragment integration and nullable Session token details. |
| `d7d7b39f-e8a8-4c3e-921d-c8d4aa1da455` | Independently authored Usage function fragment and integration notes; no direct production-file writes. |
| `42fb034d-8d37-4b3a-a2c5-6af3fa591af9` | Independently authored project Reuse fragment and integration notes, followed by an exclusive handoff to integrate that feature into the production renderer. |

Supervisors provide natural-language briefs, real captures and Core contracts, and perform independent validation. UI source changes and fragment integration are performed by the listed required-model conversations. No provider transcripts or temporary implementation briefs are committed.

The implementation includes explicit Agent Lab inputs and frozen-approval review, exact project/provider/session evidence links, nullable usage presentation, and project Codex reuse configuration through the existing preview/apply/undo boundary. It does not infer provider trust, agent adoption, future improvement or missing token counts. The native bridge change in this refinement is limited to the named `lab.promote`, `reuse.preview` and `reuse.outcomes` allowlist entries; `reuse.context` remains unavailable to the renderer.

The supervisor reviewed the current client at 1,250 × 800 and 900 × 620 pixels and accepted the visual direction. Independent checks of extracted, actual Lab functions passed nine source-isolation and delayed-response cases. The required-model Usage fragment passed syntax validation and eight groups of isolated function checks, including missing values, genuine zero, observed subsets, overflow and stale-response guards. These are scoped checks, not complete browser or native acceptance. Final real-RPC regression, native captures and packaged verification for this refinement are recorded by the release owner after integration. The Preview 2 twelve-group acceptance results above are historical and must not be read as results for this newer renderer.

The release owner records the new final workspace capture separately as `docs/assets/vela-workspace.png`; the Preview 2 session and approval images remain historical assets. After native review, the Reuse author briefly resumed conversation `42fb034d-8d37-4b3a-a2c5-6af3fa591af9` for one copy-only correction: the configuration explanation no longer exposes an internal RPC method name. The supervisor verified that exactly one text line changed and all surrounding source bytes stayed unchanged. Node syntax validation passed. The resulting renderer SHA-256 is `01104e7fbeef5c24a08af20fe70bd1934dc82f1446f7e16e230b03688ee3af0b`; the final source CI passed 95 XCTest cases and both renderer suites (18 checks) against this text revision; see [the recorded run](../evidence/2026-09-13-ci-final.json).

### Refinement cleanup

All four refinement conversations exited normally, and the supervisor closed its isolated browser session. After the release owner confirmed the final native Reuse preview/apply/reopen/undo flow, cleanup removed the 26 explicitly enumerated files in the disposable `blume-ui` scratch directory: implementation/review briefs, generated integration fragments and notes, two mechanical source snapshots, ten temporary review images, and the temporary-access manifest. It also removed that empty directory and the one default browser-cache screenshot created by this task. Formal acceptance evidence, native delivery captures, source files and reusable dependencies remain intact.

Cleanup removed exactly the one task-added repository read permission and the one task-added workspace-trust entry from the latest CLI settings. All other settings were preserved. Provider history, credentials and pre-existing permissions were not deleted; shared native fixtures, packaging outputs and reference captures remain under the release owner's cleanup scope.

## Workflow

The initial headless attempts stopped at an explicit repository read-permission request before generating files. The same model and effort were used interactively to establish scoped repository access. Subsequent implementation and correction passes reused that conversation through `--conversation`, without changing models. No blanket permission bypass was used.

Every client, native host, website and icon source change was authored through Antigravity. The supervising agent supplied briefs and reviewed backend contract compatibility, copy accuracy, native bridge boundaries, resource loading and refresh behavior. It ran validation separately. Packaging, backend implementation and deployment were outside the UI author's scope.

## Previous preview validation

- Swift compilation of the `VelaApp` target passed during native-host validation. The launchable GUI product is `VelaDesktop`; the helper is `vela`. A final packaging-only change excludes the SwiftPM `Bundle.module` fallback when `VELA_PACKAGED` is defined, retaining the development fallback for ordinary `swift run`; the release owner performs the final packaged build verification.
- Client `app.js`, browser-only `demo.js` and website `site.js` passed Node syntax checks.
- All four website pages passed static local-link and anchor validation.
- The injected JavaScript bridge passed direct runtime checks for response resolution, rejection, timeout selection, pending-request limits and teardown.
- Direct runtime checks of the actual form event handlers passed for command argument validation, preserving workflow Guidelines, retaining an existing Memory lifecycle state, and passing all four optional Recall context fields. Those checks stubbed the DOM and RPC transport and did not run external commands.
- The project owner verified the packaged macOS app against a separate synthetic sample store, including session details, saving a candidate Memory, and workflow approval followed by a completed real run.
- After the last client changes, the project owner relaunched the packaged app and confirmed that the CSP allowed the real four-session view and its visible inferred-status annotation.

Raw CLI logs, private reference material, absolute workstation paths and temporary implementation briefs are excluded from this record. This is provenance metadata, not a transcript or a claim of production signing, notarization, browser visual QA or complete agent evaluation.

## Previous preview cleanup

Removed the six disposable implementation briefs, the isolated UI validation build and the logs created by these CLI invocations. Removed task-specific temporary permission entries and workspace trust after implementation, while preserving pre-existing settings and history. UI source files and website staging remain available for packaging and publication.

## Full-capability expansion UI, 13 September 2026

The expanding desktop interfaces continue to use actual Antigravity CLI 1.2.2 with `--model gemini-3.8-flash-high --effort high --mode accept-edits --prompt-interactive`. Conversation `c04468b5-9bb3-4803-afbb-c9a748de7112` authored the new workflow, model, quota, setup, semantic/archive, Library and Watch interfaces and exact native bridge entries. Supervisors implemented the independent Core contracts and synthetic real-helper browser tests, reviewed the resulting UI, and supplied corrections. They did not author frontend or native interface code.

Independent frozen consumer tests exposed missing Ask approval inputs, stale same-modal history responses replacing a New-question draft, and lost follow-up scope. Earlier UI runs and these failures are retained separately; they are not final-checkout acceptance. The long author conversation was interrupted during a remaining localization edit and exited with its resume ID recorded. Remaining corrections continue in bounded conversations using the same required model/effort, preserving all completed source changes. Final UI hashes, strict browser and native results will be recorded after those corrections.

Conversation `7da01d5b-e71b-49d7-8608-a63e36ef241e` used the same required Gemini 3.8 Flash High model and high effort to implement the three Ask consumer corrections in `app.js` and `i18n.js`, then exited normally. A temporary provider quota delay cleared without changing the model. The independent real-helper round 6b passed all three scenarios and both dictionaries had 1,835 keys with no missing literal references. UI snapshot and helper digests are recorded in the public evidence summary. The same revised assertion still reproduces the defects on the earlier UI. Further Setup, workflow and presentation corrections remain a separate author conversation.
