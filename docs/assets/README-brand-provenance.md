# README brand artwork / README 品牌素材来源

The README header is original Vela artwork. The editable source and delivered asset are the same standalone file: [`vela-readme-banner.svg`](vela-readme-banner.svg). It is **1280 × 320**, **5,394 bytes**, with no raster image, remote font, script, animation or external resource. There is no separate generator or build dependency.

README 头图为 Vela 原创素材，SVG 同时是可编辑源与交付文件，无须生成器或构建依赖。图标沿用仓库已有的原创帆形几何，不包含参考产品的品牌、界面或素材。它是品牌横幅，不是真实软件界面截图。

## Authorship

The SVG and both README presentation changes were actually authored through **Antigravity CLI 1.2.2**, requested model **`gemini-3.8-flash-high`**, effort **`high`**, on **2026-09-13** (Asia/Shanghai).

- Conversation: `e774fa83-f032-4c67-9176-8000347afea0`.
- Invocation flags: `agy --model gemini-3.8-flash-high --effort high --mode accept-edits --prompt-interactive <scoped README brief>`.
- The executable was the installed Antigravity CLI. The prompt was restricted to the two READMEs, the existing Vela icon and screenshot references, and the new banner. Personal absolute paths are omitted here.
- The author made the SVG filter-region correction, increased supporting-text legibility and removed the repeated README tagline after actual browser review. Other agents reviewed, rendered and checked the result; they did not draw the artwork or implement the presentation edits.
- The provider tool record contains writes only to `README.md`, `README.zh-CN.md` and this new SVG. Provider session logs and credentials are not included in the repository.

头图与中英文 README 排版均由上述指定模型实际写入；后续阴影裁切修正、辅助文字字号与重复标语删减也由同一作者会话完成。

## References and ownership

Only two official public READMEs were consulted on **2026-09-13**:

- [Zed](https://github.com/zed-industries/zed): concise product positioning and direct installation/development links.
- [Ghostty](https://github.com/ghostty-org/ghostty): compact brand/navigation grouping and a separate explanation of product status.

These references informed reading order, not visual assets or product claims. The banner reuses the polygon geometry from Vela's own [`app-icon.svg`](../../Sources/VelaApp/Resources/Design/app-icon.svg), with an independent banner composition. It follows the repository's [MIT license](../../LICENSE).

参考仅涉及信息组织，不复制商标、视觉素材、代码或能力宣传。没有添加星标数量、用户规模或未经测量的性能宣传。

## Validation and limits

Both READMEs were rendered successfully using the actual GitHub Markdown API. The returned HTML was checked in Chromium with official GitHub styles inside a local preview container: English and Chinese at 1100px, dark mode at 1100px, an 850px content column, and both languages at a 390px mobile viewport. All six checks passed: images loaded, the banner fit the content column and no page-level horizontal overflow appeared. Code blocks retain GitHub's intentional internal horizontal scrolling. This is a local rendering check, not proof that a new repository revision has already been published.

The SVG has `viewBox`, explicit dimensions, `role="img"`, title and description. Both READMEs provide localized alt text and normal text positioning outside the image. XML checks reject active content and external resource references. Local README references resolve, and release links remain the exact `v0.1.0-preview.2` tag. The existing CI badge is retained; decorative third-party badge images were removed.

Each README retains all six original fenced command/configuration examples byte-for-byte. The presentation pass preserves the existing sections apart from the displayed MIT link label; a subsequent documentation update adds the development client's language-switching instructions. Installation, signing/notarization warnings, acceptance limitations and supported privacy/network boundaries remain visible.

The existing `vela-workspace.png`, `vela-sessions.png` and `vela-approval.png` files were not edited: their before/after SHA-256 values match. The displayed workspace image remains separate from the banner, with its existing caption identifying an actual macOS development build, synthetic session data and its absence from the preview.2 download.

中英文文档均经真实 GitHub Markdown 渲染及宽窄屏检查。现有章节、六段命令/配置示例、签名与公证限制、完整验收未通过的状态均保留。原有三张真机截图未改动，开发分支与已发布下载的区别仍明确标注；本次视觉调整不构成产品能力或发布状态的新增证明。

Local review evidence is retained under `output/playwright/readme-brand/` (not a release resource). The shipped SVG SHA-256 is:

```text
43125fefe9e606fda4335c8c9271f55d406134fa3ab98e5216a4c574259f6171
```
