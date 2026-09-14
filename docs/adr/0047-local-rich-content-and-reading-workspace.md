# ADR 0047: Local rich content and a dedicated reading workspace

Status: Accepted · 2026-09-14

The desktop previously showed Markdown as escaped text, clipped approval previews to three lines, and reserved 480 px for details even when both resulting columns became hard to read. The user explicitly authorized direct Codex UI implementation, superseding the prior external-model authoring constraint.

Keep AppKit, WKWebView and the Swift helper. Details replace the main content region while the project/navigation sidebar stays available; the hidden originating region becomes inert until the user returns. Existing project/run/instance guards still reject stale replies. This changes presentation, not approval authority or persistence.

Bundle fixed local Marked, DOMPurify and a small Prism language set, with versions and byte hashes in `docs/implementation/renderer-vendor-lock.json`. No CDN, runtime Node dependency, autoloading, network image loading or automatic language detection. Markdown raw HTML is escaped; a final strict DOMPurify tag/attribute allowlist removes navigation, media, style, scripts, identifiers and handlers. Provider text cannot create application action selectors. Large Markdown falls back to exact plain text; code highlighting has document and longest-line limits. HTML renderer fallback must remain inert.

Approval content has preview/source views and copies the exact original string, including whitespace. The original frozen approval parameters and Core checks remain authoritative; rendering is never proof that the operation is safe or succeeded. Source remains available when highlighting is skipped. UI resources, licenses and fixture snapshots share an explicit release allowlist.

Alternatives: a custom regex Markdown parser is harder to maintain and secure; a full editor brings unnecessary interaction/runtime weight to a read-only viewer. The local dependencies add approximately 120 KB before the adapter and styles. Revisit if editing or unsupported languages become a concrete need.

Validation requires Markdown/code/escaping, adversarial content, exact whitespace copy, large-content bounds, locale switching, keyboard menus, 900–1440 px layout, real helper approval regression and native WKWebView inspection. Browser-only evidence is identified separately.

中文：保留原生轻量架构，将详情改为主区阅读。内置固定版本的本地 Markdown、清理和语法高亮依赖，内容不自动联网；大文本回退原文。审批原文完整可查，权限边界不变。需分别验证真实 helper 与原生界面。
