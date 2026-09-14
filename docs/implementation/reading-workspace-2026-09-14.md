# Reading workspace and product catalogue

The 2026-09-14 user correction requested direct Codex implementation. This revision replaces the compressed split inspector with a dedicated main reading area, keeping project navigation available. Returning to a page restores the list; explicit navigation starts at the heading, while background refresh preserves reading position.

Memory separates status filters from three primary controls: Ask, Tools and New Memory. Import/export, indexing, reuse setup and recall diagnostics remain in Tools; lifecycle/edit/history actions use per-record menus. Menus support keyboard disclosure, Escape and outside dismissal.

Session prose and approval files now use local Markdown rendering, bounded syntax highlighting and full source inspection. Approval content is no longer clipped to three lines. Copy retains the exact original text including leading/trailing newlines and CRLF. Raw HTML, images and links cannot trigger scripts or network requests. [ADR 0047](../adr/0047-local-rich-content-and-reading-workspace.md) and the [vendor lock](renderer-vendor-lock.json) document dependency, packaging and security boundaries.

The bilingual site contains 32 pages: Product (12 capability areas), Use Cases (8 actual engineering tasks), Integrations, Comparisons, Docs, Releases and Privacy. The homepage has a restrained multicolour final headline. Public download links still target preview.2; source-only capabilities are identified. Current redesign screenshots are explicitly labelled local browser verification with a real helper, not native verification.

## Local evidence

All flows below used synthetic local records and the real Swift helper, not user projects or a remote model. Evidence is retained in the local `output/playwright` tree.

| Check | Result | Evidence directory |
| --- | --- | --- |
| Reading layout, main-region navigation, Memory menus, actual approval preview/source/copy, English and 900 px | 5/5 | `reading-workspace-r2` |
| Long assets, frozen approval wire, expired approvals, late project replies, locale/narrow controls | 6/6 | `reading-usability-r1` |
| Run-feedback initial read race, errors, stale project/run/close, header geometry | 4/4 | `reading-feedback-drawer-r7` |
| Session-to-memory provenance, confirmation, idempotency and scope guards | 5/5 | `reading-memory-capture-r3` |
| Locale surfaces, preserved user content, selected records and menus | 6/6 | `reading-localization-r2` |
| Memory lifecycle and reuse Apply/Undo diagnostic subset | 2/2 (subset) | `reading-acceptance-menu-r2` |
| Rich content injection, code rendering, exact copy, large text and locale | 6/6 | `reading-final-rich` |
| Ask and engineering consumers after bridge cache fix | 11/11 | `engineering` |
| Bilingual website links/resources/locale/responsive behaviour | 32 pages, zero failures | `website-reading-r3` |

Earlier failed runs are retained: a missing nested English asset prefix, a navigation scroll-position defect, old split-view test paths and old plain-text viewer selectors were corrected. Passing suites record source hashes. Earlier slice runs do not replace later source verification.

A separate test-bridge bug caused the previous GitHub CI failure: an approval delivered by `ask.get` was not cached as a displayed approval. The fixture bridge now records the exact returned approval identity just as it does for Inbox. It still checks project, snapshot hash, tool and arguments; no product approval checks were weakened.

## Remaining boundaries

Native WKWebView interaction for this specific redesign is pending because macOS is locked. No browser screenshot is counted as native completion. The build is arm64, ad-hoc signed and unnotarized. This UI revision does not close the 188/228 requirement ledger or all release gates. The earlier 514-test CI core result belongs to its recorded commit and is not a new full-product acceptance result.

## 中文说明

本轮直接重构主区阅读、Memory 菜单、审批格式化预览与完整源码，修复跨页面遗留滚动位置。官网扩为 32 个中英文页面、12 项能力和 8 个场景。上表为真实本地 helper 浏览器检查，原生交互仍待 Mac 解锁后验证；总体功能和发布验收没有因此标记全部完成。
