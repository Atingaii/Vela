# Product image provenance

The screenshots in this directory show Vela's actual macOS AppKit/WKWebView application, connected to the real local `vela` helper. They use an isolated, synthetic Harbor project created by `scripts/create-ui-fixture.py` through production CLI methods and supported log parsers.

No personal sessions, user projects, account credentials or reference-product screenshots are included. The data is deliberately synthetic; the interface and its responses are real. These images are product illustrations, not evidence of a completed real-world agent task or benchmark improvement.

The native WebKit viewport is exported without visual editing by the development-only capture command. Release builds exclude this command. Copies in `website/dist/assets/` use the same pixels. When refreshing an image, regenerate the fixture, inspect the actual app state, capture it again, and update the verification record.

The Vela icon and notification sound source files, generation details and license are documented under `Sources/VelaApp/Resources/Design/`. Website font licenses accompany the self-hosted font files. Third-party product references are not redistributed as Vela assets.
