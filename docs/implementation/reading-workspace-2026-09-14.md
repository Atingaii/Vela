# Reading workspace and product catalogue

The 2026-09-14 user correction requested direct Codex implementation. This revision replaces the compressed split inspector with a dedicated main reading area, keeping project navigation available. Returning to a page restores the list; explicit navigation starts at the heading, while background refresh preserves reading position.

Memory separates status filters from three primary controls: Ask, Tools and New Memory. Import/export, indexing, reuse setup and recall diagnostics remain in Tools; lifecycle/edit/history actions use per-record menus. Menus support keyboard disclosure, Escape and outside dismissal.

Session prose and approval files now use local Markdown rendering, bounded syntax highlighting and full source inspection. Approval content is no longer clipped to three lines. Copy retains the exact original text including leading/trailing newlines and CRLF. Raw HTML, images and links cannot trigger scripts or network requests. [ADR 0047](../adr/0047-local-rich-content-and-reading-workspace.md) and the [vendor lock](renderer-vendor-lock.json) document dependency, packaging and security boundaries.

The bilingual site contains 32 pages: Product (12 capability areas), Use Cases (8 actual engineering tasks), Integrations, Comparisons, Docs, Releases and Privacy. The homepage has a restrained multicolour final headline. Public download links still target preview.2; source-only capabilities are identified. The homepage and README show an actual native WKWebView development capture with synthetic data; released preview.2 screenshots retain their own labels.

## Local evidence

All flows below used synthetic local records and the real Swift helper, not user projects or a remote model. Evidence is retained in the local `output/playwright` tree.

| Check | Result | Evidence directory |
| --- | --- | --- |
| Reading layout, main-region navigation, Memory menus, actual approval preview/source/copy, English and 900 px | 5/5 | `reading-workspace-r2` |
| Long assets, frozen approval wire, expired approvals, late project replies, locale/narrow controls | 6/6 | `reading-usability-r1` |
| Run-feedback initial read race, errors, stale project/run/close, header geometry | 4/4 | `reading-feedback-drawer-r7` |
| Session-to-memory provenance, confirmation, idempotency and scope guards | 5/5 | `reading-memory-capture-r3` |
| Locale surfaces, preserved user content, selected records and menus | 6/6 | `reading-localization-r2` |
| Full renderer flow, guards and existing actions | 12/12 | `reading-full-ui-browser-r2` |
| Full parity browser journeys | 5/5 | `reading-full-parity-r1` |
| Full Memory lifecycle and reuse acceptance | 6/6 | `reading-full-acceptance-r1` |
| Rich content injection, code rendering, exact copy, large text and locale | 6/6 | `reading-final-rich` |
| Ask and engineering consumers after bridge cache fix | 11/11 | `engineering` |
| Bilingual website links/resources/locale/responsive behaviour | 32 pages, zero failures | `website-reading-r6` (including 10 bilingual category/count/ARIA checks and the final native image) |

Earlier failed runs are retained: a missing nested English asset prefix, a navigation scroll-position defect, old split-view test paths and old plain-text viewer selectors were corrected. Passing suites record source hashes. Earlier slice runs do not replace later source verification.

A separate test-bridge bug caused the previous GitHub CI failure: an approval delivered by `ask.get` was not cached as a displayed approval. The fixture bridge now records the exact returned approval identity just as it does for Inbox. It still checks project, snapshot hash, tool and arguments; no product approval checks were weakened.

## Native observations

After the Mac became available, the actual AppKit/WKWebView QA wrapper was launched against the isolated fixture. Session reading, code highlighting, Memory tool disclosure and Escape, approval Markdown/Source/Copy feedback, language switching and quit/relaunch persistence were observed. Clicking Approve & Run wrote the expected 50 bytes to `Harbor/docs/verification.md`; the approval count changed from three to two and remained two after restart. Sound preview reported success without requesting OS notification permission. This records the action result, not an acoustic evaluation or notification delivery.

The [native receipt](../evidence/2026-09-14-reading-native.json) includes 21 renderer resource hashes and the unedited screenshot hashes. The dev package at `releases/development-953d5a0` contains the same renderer bytes. Its release executable is distinct from the development QA host. Full native feature coverage, signed installation and system notifications remain separate gates.

## Remaining boundaries

This redesign has focused native evidence, not full product native completion. The build is arm64, ad-hoc signed and unnotarized. This UI revision does not close the 188/228 requirement ledger or all release gates. The earlier 514-test CI core result belongs to its recorded commit and is not a new full-product acceptance result.

## 中文说明

本轮直接重构主区阅读、Memory 菜单、审批格式化预览与完整源码，修复跨页面遗留滚动位置。官网扩为 32 个中英文页面、12 项能力和 8 个场景。上表为真实本地 helper 浏览器检查；本机原生已验证阅读、菜单、审批文件写入、语言及重启持久化，并保留真实截图。总体功能和发布验收没有因此标记全部完成。
