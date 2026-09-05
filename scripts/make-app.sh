#!/bin/bash
# Build a release binary and wrap it in dist/Claude View.app.
#
# Signing is optional and off by default:
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/make-app.sh
# Override the bundle id with BUNDLE_ID=... (default: com.jaydeebee.app.claude-view).
#
# VERSION sets CFBundleShortVersionString. Unset, it falls back to the
# nearest git tag; with no tag either, the app is left unversioned so
# the update check treats it as a development build instead of comparing
# a stale hardcoded number against real releases.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.jaydeebee.app.claude-view}"
if [ -z "${VERSION:-}" ]; then
    VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^[vV]//' || true)"
fi
APP="dist/Claude View.app"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=".build/apple/Products/Release/ClaudeView"
else
    swift build -c release
    BIN=".build/release/ClaudeView"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Claude View"

# The icon is generated art (scripts/make-icon.swift) checked in as an
# .icns. Missing, the build still works and macOS draws the generic app
# tile, so a checkout that has not run the generator is not broken.
ICON=""
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON="AppIcon"
fi

{
cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Claude View</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Claude View</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
EOF
if [ -n "$ICON" ]; then
cat <<EOF
    <key>CFBundleIconFile</key>
    <string>${ICON}</string>
EOF
fi
if [ -n "$VERSION" ]; then
cat <<EOF
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
EOF
fi
cat <<EOF
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
} > "$APP/Contents/Info.plist"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP"
    echo "Signed as: $CODESIGN_IDENTITY"
fi

echo "Built $APP"
