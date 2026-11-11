#!/bin/bash
# Builds SwiftMD.app (Apple silicon + Intel) in dist/, and a zip of it.
#
#   Tools/package-app.sh                 unsigned (ad-hoc) build, for trying it locally
#   SIGN_ID="Developer ID Application: Name (TEAMID)" Tools/package-app.sh
#                                        signed with your Developer ID, ready to notarize
#   ... NOTARY_PROFILE=swiftmd           also notarizes and staples (see docs/releasing.md)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.9.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-io.github.starladeer.SwiftMD}"
APP="dist/SwiftMD.app"

echo "Building SwiftMD $VERSION ($BUILD)…"
swift build -c release --product SwiftMD --arch arm64 --arch x86_64
BIN="$(swift build -c release --product SwiftMD --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SwiftMD" "$APP/Contents/MacOS/SwiftMD"

# Icon: every size macOS asks for, from the 1024 px drawing.
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Sources/SwiftMD/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Sources/SwiftMD/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
[ -f THIRD-PARTY-NOTICES.md ] && cp THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SwiftMD</string>
  <key>CFBundleDisplayName</key><string>SwiftMD</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>SwiftMD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>GPL-2.0. Use at your own risk.</string>
</dict></plist>
PLIST

if [ -n "${SIGN_ID:-}" ]; then
  echo "Signing with $SIGN_ID…"
  codesign --force --timestamp --options runtime --sign "$SIGN_ID" "$APP"
else
  echo "No SIGN_ID: ad-hoc signing (fine on this Mac, other Macs will warn)."
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

ZIP="dist/SwiftMD-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "Sending to Apple for notarization (usually a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose "$APP"
fi
echo "Done: $APP and $ZIP"
