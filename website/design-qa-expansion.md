# Website expansion design QA — 2026-09-13

final result: passed

This record covers the new site expansion, separately from historical `design-qa.md`. The corrected implementation passed the scoped checks below; earlier findings remain recorded as history.

## Source and state

- Source: live px0 `/comparisons`, light theme, captured through the Codex in-app browser. Local evidence: `output/website-expansion/02-px0-comparisons-matched-ready.png`.
- First implementation: local `/comparisons/`, light theme, `output/website-expansion/04-comparisons-initial-matched.png`.
- Both DOM viewports: 1290 × 1240 CSS pixels. Both browser screenshot payloads are JPEG-encoded at 1275 × 1226 pixels (despite the original `.png` filenames), verified with `file` and `sips`; no pixel editing or normalization was performed. The user-owned tab retains its physical viewport; the temporary reference tab was explicitly matched to it. An earlier blank loading capture was rejected.
- Both full images were inspected together in one comparison input. Text and table rows are readable at this size, so the first findings did not require a cropped-detail comparison.

## Initial findings

- P1, comparison table: long paragraphs made rows about220px high; Vela received roughly3times the width of each other product. The reference uses compact, even, scannable marks. Required correction: equal product columns, short status/differentiator cells and complete explanations in linked definitions below. Do not shrink body text to fit paragraphs.
- P1, hero and methodology: the internal O/R/V audit categories and large prose panel dominated the page and moved the matrix to about520px. Required correction: concise product introduction and baseline note, methodology below the matrix, table starting near the reference435px position.
- P1, comparative claims: several not-verified capabilities were labeled unavailable. Required correction: use the current first-party content brief, distinguish documented/planned/unverified, and pin Vela evidence links to the development source revision.
- P2, misleading affordance: horizontal-scroll hint was present even when the desktop table fitted. Show it only when needed; keep a keyboard-focusable scroll region at narrow sizes.

## Fidelity surfaces

- Typography: Space Grotesk56px heading and readable Chinese fallback are present. Cell density and text lengths need correction.
- Spacing/layout: top-level navigation direction is accepted; table proportions and hero rhythm are blocked as above.
- Colors: multicolor headline gradients removed. Light/dark and focus contrast still require final checks.
- Images: existing original Vela mark is reused; no copied reference brand or fabricated product screenshot. Final new-source image placement remains to be checked.
- Copy/content: version separation and uncertainty must follow the reviewed content brief. Independent usecase pages are not yet complete.

## Required completion checks

Capture the corrected comparison at the same state and compare again. Verify all10routes, four detail links, factor definition expansion, direct refresh, theme persistence, keyboard/mobile menu, responsive table behavior and console errors. Record exact final source hashes before publication. This is website QA, not proof that the full product Golden Scenario passed.

## Corrected implementation and final review

All initial P1/P2 findings above were corrected by the same specified UI author. The matrix now uses a 24% factor column and four equal 19% product columns; cells are 13.5px with 19.575px line height. Its top is approximately 440px at 1290 × 1240. Long definitions sit in native expandable details. Reference products use documented/planned/not-verified states with nearby first-party links. Vela evidence is pinned to the existing development source; the downloadable preview.2 remains distinct.

The final comparisons pair was recaptured in light mode through the same browser API at **1290 × 1240 CSS and image pixels**: `17-px0-comparison-final-reference.jpg` and `18-comparison-final.jpg`. The final catalogue pair uses **1280 × 720 CSS and image pixels**: `16-px0-catalogue-final-reference.jpg` and `14-usecases-final.jpg`. Dimensions were verified with `sips`. Both pairs were inspected together in one comparison input, without image editing. The earlier compressed/blank captures are not the final comparison evidence.

Typography, spacing, restrained light/dark colors, original assets and actual copy were reviewed. The reference's compact navigation, subtle grid, large headings, table layout and category controls are carried into Vela's own product content. Vela has four actual tasks and descriptive evidence cells; it does not copy px0's larger catalogue or competitive verdicts. Original mark and existing authentic synthetic-workspace screenshot are reused. Every new workspace-image placement identifies the development branch and its absence from preview.2.

Further review corrected inert category pills into real accessible filters, added a visible live result count, restricted scroll hints to overflow and removed an unsolicited `file://` rewrite. The editor's unsupported “double blind” wording was removed before publication. The final mobile catalogue was recaptured after these changes. No unresolved P1/P2 findings remain for this website scope.

## Executed checks

- Ten independent routes at 320, 390, 768 and 1280 pixels: 40 route/layout checks, no page-level horizontal overflow, one meaningful H1 and no broken loaded eager image. Four detail pages have distinct headings and content. Navigation URLs and labels are consistent across all pages.
- Actual clicks through all four catalogue detail links, then each return link; correct independent URLs and headings.
- All four category filters plus All reset: the exact intended rows remain visible and `aria-pressed` follows selection. The final live status changes to `显示 1 / 4 个场景` and returns to 4 / 4.
- Factor link opens its exact definition; direct refresh preserves the hash-selected open definition. Keyboard Enter expands all ten; Collapse All closes all ten.
- Theme survives a real refresh and navigation between pages. Desktop light/dark, mobile comparison/catalogue, homepage, detail page and documentation screenshots were visually reviewed.
- Mobile navigation moves focus to its first link; Escape closes it and restores focus. The comparison scroll region is keyboard focusable, ArrowRight changes its scroll position, and its first column is not sticky on the narrow viewport, allowing full cells to be read.
- The strengthened repository checker validates all local resources, all ten required HTML files, duplicate IDs and cross-page hash anchors. Existing homepage anchors and `.html` documentation/release/privacy URLs still resolve.
- Browser error/warning logs were empty during the recorded checks. Website code remains static HTML/CSS/JavaScript with self-hosted fonts and no added framework, tracker or runtime dependency.

Local evidence is in `output/website-expansion/`: `route-checks.json`, `interaction-checks.json`, final source hashes and numbered unedited browser captures. These files are review evidence, not application resources or new product screenshots. The final source hash manifest contains 21 static files (ten HTML pages), totalling 1,090,918 bytes. No real provider experiment ran as part of this website work. This QA result does not change the overall product Golden Scenario's No-Go state.

## Authorship

All new website HTML, CSS, interaction code and visual/copy corrections were actually implemented through Antigravity CLI **1.2.2**, requested **gemini-3.8-flash-high**, effort **high**, conversation `f97031ec-0b1a-4922-8477-d45079000fc9`, on 13 September 2026 (Asia/Shanghai). The owner supplied bounded briefs, reviewed screenshots and code, copied the already-owned workspace PNG byte-for-byte, strengthened non-UI checks, and managed hosting. The author session exited normally after the final corrections. Its private session logs and temporary prompts are not shipped.

## Publication check

The public Site was verified with all ten actual page headings after deployment. Hosting redirects the legacy `.html` addresses to `/docs`, `/releases` and `/privacy`; their content and anchors remain reachable. An initial probe read during navigation before the headings appeared; the final probe waits for the actual visible H1. Both records are retained locally. A subsequent two-paragraph privacy correction explicitly limits Private Library exclusion to Vela retrieval and does not claim a filesystem sandbox for separately approved third-party commands. The same UI author made it; 390px and 1280px layout checks passed, and only `privacy.html` changed from the initial published source.

The final publication is saved Site version **4**, source commit `102d94a1457c29c35eeb9c1415eb8f9d75450b6e`, deployed successfully at [the public website](https://vela-engineering.zzzsssaa.chatgpt.site/). The 22-file archive contains the 21 validated static files and hosting manifest; all static SHA-256 values match the pushed source. The live privacy wording was verified after this final deployment. See [the scoped evidence record](../docs/evidence/2026-09-13-website-expansion.json).
