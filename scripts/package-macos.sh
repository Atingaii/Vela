#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VELA_CHANNEL="${VELA_CHANNEL:-dev}"
case "$VELA_CHANNEL" in dev|canary|stable) ;; *) echo "Unknown channel" >&2; exit 1;; esac
if [[ -n "${VELA_NOTARY_PROFILE:-}" && -z "${VELA_SIGN_IDENTITY:-}" ]]; then
  echo "Notarization requires VELA_SIGN_IDENTITY and VELA_NOTARY_PROFILE." >&2
  exit 1
fi
swift build -c release --arch arm64 -Xswiftc -DVELA_PACKAGED -Xswiftc -gnone -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
VELA_BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
VELA_BUNDLE="$PWD/releases/Vela.app"
mkdir -p "$VELA_BUNDLE/Contents/MacOS" "$VELA_BUNDLE/Contents/Resources/UI"
install -m 755 "$VELA_BIN_DIR/VelaDesktop" "$VELA_BUNDLE/Contents/MacOS/VelaDesktop"
install -m 755 "$VELA_BIN_DIR/vela" "$VELA_BUNDLE/Contents/MacOS/vela"
python3 scripts/package-resources.py "$VELA_BUNDLE" "$VELA_CHANNEL"
if [[ -n "${VELA_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$VELA_SIGN_IDENTITY" "$VELA_BUNDLE/Contents/MacOS/vela"
  codesign --force --options runtime --timestamp --sign "$VELA_SIGN_IDENTITY" "$VELA_BUNDLE"
else
  codesign --force --sign - "$VELA_BUNDLE/Contents/MacOS/vela"
  codesign --force --sign - "$VELA_BUNDLE"
fi
codesign --verify --deep --strict "$VELA_BUNDLE"
python3 scripts/release-audit.py "$VELA_BUNDLE"
ditto -c -k --sequesterRsrc --keepParent "$VELA_BUNDLE" "releases/Vela-macOS-arm64.zip"
(cd releases && shasum -a 256 Vela-macOS-arm64.zip > SHA256SUMS)
if [[ -n "${VELA_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit releases/Vela-macOS-arm64.zip --keychain-profile "$VELA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$VELA_BUNDLE"
  ditto -c -k --sequesterRsrc --keepParent "$VELA_BUNDLE" releases/Vela-macOS-arm64.zip
  (cd releases && shasum -a 256 Vela-macOS-arm64.zip > SHA256SUMS)
fi
echo "Packaged: $VELA_BUNDLE"
