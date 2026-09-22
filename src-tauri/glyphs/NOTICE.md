# Provider marks

The SVG files in this directory come from the npm package `@lobehub/icons-static-svg` 1.95.0
(https://github.com/lobehub/lobe-icons, MIT License) and are unmodified:

| File | Original file in the package | Shown in |
|---|---|---|
| claude.svg | icons/claude.svg | Claude cell |
| codex.svg | icons/openai.svg | Codex cell (the OpenAI mark, matching upstream Codenotch's glyph choice) |
| codex-alt.svg | icons/codex.svg | alternative: Codex's own mark |
| cursor.svg | icons/cursor.svg | Cursor cell |
| grok.svg | icons/grok.svg | Grok cell |
| gemini.svg | icons/antigravity.svg | Antigravity cell |
| gemini-alt.svg | icons/gemini.svg | alternative: the Gemini spark |

MIT License — Copyright (c) LobeHub. See that repository's LICENSE.

**Trademarks**: these marks are trademarks of Anthropic, OpenAI, Anysphere (Cursor), xAI (Grok) and Google
respectively, and are used here only to identify the product whose usage is displayed. Whether
they stay in a distributed build is the repository owner's call under each brand's guidelines;
they can be swapped for generated glyphs without touching any code.

**Overrides**: a file of the same name (`.svg` or `.png`) in `%APPDATA%\codenotch\glyphs\` takes
precedence over the built-in mark; it is picked up after "Refresh usage now" in the tray menu.

## Swift parity resources

`swift/` comes from Codenotch (Vinz, MIT), pinned to
`117a38b8edae2ebd0944bc86b8760c6381685345`. `manifest.json` records each
original path, outline name where applicable, and generated/copied SHA-256.
`scripts/import-swift-glyphs.py` reproduces these files: image catalog bytes
are unchanged; `GlyphOutline.swift` CGPoint loops become equivalent closed
SVG paths with even-odd fill. The Swift `ProviderGlyph.opticalScale` values
are preserved by the renderer. Catalog images use template masks, as in Swift.
These marks identify their respective providers; all trademarks remain with
their owners. The older LobeHub files above remain as provenance, but the
Swift resources now supply the default marks.
