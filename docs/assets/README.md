# Product image provenance

The screenshots in this directory show Vela's actual macOS AppKit/WKWebView application, connected to the real local `vela` helper. They use an isolated, synthetic Harbor project created by `scripts/create-ui-fixture.py` through production CLI methods and supported log parsers.

No personal sessions, user projects, account credentials or reference-product screenshots are included. The data is deliberately synthetic; the interface and its responses are real. These images are product illustrations, not evidence of a completed real-world agent task or benchmark improvement.

The native WebKit viewport is exported without visual editing by the development-only capture command. Release builds exclude this command. When refreshing an image, regenerate the fixture, inspect the actual app state, capture it again, and update the verification record.

- `vela-workspace.png` shows the unreleased acceptance branch at source commit `91d34e2`, captured after a standard LaunchServices launch of an isolated development wrapper at 1250 × 800. Its pixels and SHA-256 are recorded in [UI evidence](../evidence/2026-09-13-ui.json). It is not included in the preview.2 download or current website assets.
- `vela-sessions.png` and `vela-approval.png` retain the released preview.2 interface. Their copies in `website/dist/assets/` use the same pixels.

The Vela icon and notification sound source files, generation details and license are documented under `Sources/VelaApp/Resources/Design/`. Website font licenses accompany the self-hosted font files. Third-party product references are not redistributed as Vela assets.

`vela-reading.png` is the actual native WKWebView viewport at 1250 × 800 from source `953d5a0`, captured without pixel editing during `native-reading-r2` using the real Swift helper and synthetic records. [Capture hashes and focused native observations](../evidence/2026-09-14-reading-native.json) distinguish this development QA wrapper from a notarized release and full product acceptance. Older native screenshots remain separate historical assets.
