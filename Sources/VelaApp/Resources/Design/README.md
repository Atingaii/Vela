# Vela brand assets

The icon SVG, compact mark and notification synthesis source were authored through
Antigravity CLI Gemini 3.8 Flash (High), with original Vela geometry and tones.
They are covered by this repository's MIT license; no third-party sound samples
or reference-product branding are used.

`app-icon.png` is a lossless 1024×1024 rasterization of `app-icon.svg`, preserving
transparent corners. The approved raster is included so macOS contributors can
rebuild the `.icns` with system tools:

```sh
python3 scripts/build-icon.py
python3 Sources/VelaApp/Resources/Design/generate-sounds.py
python3 scripts/test-release-resources.py
```

Run these commands from the repository root. Sound generation is deterministic
and uses the Python standard library. Delivery contains the icon and three short
WAV files, not these source scripts or design documentation. UI authorship and
review are recorded in [the implementation notes](../../../../docs/implementation/antigravity-ui.md).
