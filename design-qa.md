# Vela product experience design QA

Date: 12 September 2026. Candidate: `0.1.0-preview.2`.

## Visual truth and method

- Website reference: [px0.ai](https://px0.ai/), captured in light and dark themes. Desktop reference: `output/playwright/px0-desktop-before.png` (1440 × 1000 pixels); mobile: `output/playwright/px0-mobile-before.png` (390 × 844 pixels). These local reference captures are ignored by Git and are not redistributed as Vela product assets.
- Desktop implementation, first paired comparison: `output/playwright/vela-website-iteration1.png` (1440 × 1000). The reference and implementation were supplied together in a single image-comparison input, at the same top-of-page position, light theme and 1 device-pixel-per-CSS-pixel density. An earlier 1280 × 633 capture was replaced before assessing fidelity.
- Mobile comparison: reference 390 × 844 and `.task-tmp/website-redesign/index-mobile-qa.png` at the same viewport, density, scroll position and theme, supplied together in a single comparison input.
- Client reference: the actual GitHub Desktop product UI, together with conventional macOS sidebar, inspector and keyboard patterns. This is a product redesign, not a pixel clone of another application's content or chrome. Native Vela captures use the real AppKit/WKWebView app and CLI against the isolated Harbor fixture.
- Native diagnostic captures: `output/playwright/native/vela-agents-1789217385.png` and `output/playwright/native/vela-agents-1789218033.png`, each a 1250 × 800 WebKit viewport at 1× export density. The macOS traffic-light buttons are native overlays and are outside the WebKit export.

## Fidelity review

| Surface | Assessment |
| --- | --- |
| Typography | Desktop website uses the actual self-hosted Space Grotesk and Inter fonts. The 118px three-line heading, approximately 1:1 line height, tight tracking and 52px section headings follow the reference. Mobile heading wraps naturally at about 48px. The client uses macOS system text; prose and code have separate treatments. |
| Layout and spacing | Website desktop content starts at x=258 inside the 924px hero and 1124px navigation/section container. The near-960px hero, 64px background grid, square CTA and code bar match the reference's hierarchy. The wide inspector and the 900 × 620 narrow-window drawer were verified in native WebKit. |
| Color | Default light website, near-white surface, dark text, muted secondary copy, subtle warm/cool wash and amber-to-violet headline. A user-selectable dark theme is retained. Semantic client states keep text labels alongside color. |
| Assets | Original Vela SVG/icon raster and generated sounds; no px0 branding or fake product window is shipped. The published image files are actual native captures of synthetic data, with no private user sessions. Self-hosted font license files and source metadata are present. |
| Copy | Vela-specific product and preview claims replace reference copy. Downloads name the exact preview release. Documentation is checked against the actual CLI, archive and storage paths. |

The visible copy length, original Vela mark, Chinese explanatory text and mobile navigation button are intentional differences. They support this product and its four pages without changing the reference's visual hierarchy.

## Iteration history

| Priority | Finding and evidence | Correction | Post-fix evidence |
| --- | --- | --- | --- |
| P1 | Previous public site used an unrelated dark, compact hero (`output/playwright/vela-website-before.png`). | Rebuilt the four-page design through the required Antigravity model using the actual px0 light reference. | Paired desktop and mobile comparisons above show the correct hierarchy. |
| P1 | Long session ID displaced inspector action/close buttons in a native window. | Moved ID into expandable technical metadata and constrained the header. | Second native diagnostic capture shows both actions visible. |
| P2 | Status annotation wrapped one character per line; normal messages appeared as code blocks. | Non-wrapping statuses and system-font prose, preserving explicit inferred-state labels. | Second native diagnostic capture shows readable labels and message paragraphs. |
| P1 | Modal inspector prevented continuous list browsing. The first split revision then produced unnecessary table scrollbars and clipped the fifth row. | Use a wide-window nonmodal inspector, then reduce its companion list to task/status and prevent flex shrink. | `docs/assets/vela-sessions.png` shows all five rows and the complete inspector at 1250 × 800. |
| P1 | Native session table disappeared from the accessibility tree after rows were assigned button roles. | Preserve table-row semantics and use real buttons in title cells. | Native accessibility exposes title controls and rows; actual click opens details, and Escape closes the narrow drawer. |
| P1 | Page content and active navigation disagreed during native inspection. | Protect asynchronous responses and project scope. A separate native diagnostic then isolated stale CSS transition styling despite correct active classes; remove the nonessential navigation background transition. | Native before/after DOM, computed styles and PNG agree for consecutive Workflows and Inbox navigation (`vela-workflows-A087C35D-8382-435E-A0BF-8B5B2AFA4377`, `vela-inbox-53CD7F50-17F3-4356-8F77-B8FB3750C399` under `output/playwright/native`). No broader WebKit engine cause is asserted. |
| P2 | Mobile ownership content overflowed horizontally; documentation initially opened with a full-height table of contents. | Bound long preformatted content and add a collapsible mobile contents section. | The four-page 320/390/768/1440 browser matrix and final product-image review passed; see `website/design-qa.md`. |

## Final visual evidence and interaction checks

The final 1440 × 1000 light desktop and 390 × 844 light mobile website captures (`output/playwright/vela-website-final-desktop.png` and `vela-website-final-mobile.png`) were each supplied with the matching px0 capture in one comparison input. Typography, content bounds, grid, primary button treatment and hierarchy match the reference; the stated copy and branding differences remain intentional.

The native 900 × 620 capture `output/playwright/native/vela-agents-B0FFCBC6-2972-4702-A0E2-6A3C01F8D961.png` shows the drawer with readable messages and visible Checkpoint, Memory and close controls. Escape returned to the session table. The final approval image is `docs/assets/vela-approval.png`; the correct Inbox navigation highlight, project, file target, content summary and approval buttons are all visible.

Core and notification policy: 54 real-core methods passed the portable runner, which is not XCTest. The final 12-scenario real-CLI renderer suite, native audio checks, website product images and packaged application checks passed as recorded in `docs/verification.md`. OS notification authorization remains an explicit environment limitation, not a visual pass claim.

Final result: passed

Visual, image integration, native accessibility, renderer interaction and packaged application checks are complete with no remaining design blockers. This design acceptance does not certify OS notification delivery, signing/notarization, or unimplemented roadmap capabilities; their boundaries are explicit in the verification and status records.
