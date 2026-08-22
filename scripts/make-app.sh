#!/bin/bash
# Build a release binary and wrap it in dist/Claude View.app.
#
# Signing is optional and off by default:
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/make-app.sh
# Override the bundle id with BUNDLE_ID=... (default: local.claude-view).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-local.claude-view}"
VERSION="0.1.0"
APP="dist/Claude View.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeView "$APP/Contents/MacOS/Claude View"

cat > "$APP/Contents/Info.plist" <<EOF
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
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$CODESIGN_IDENTITY" "$APP"
    echo "Signed as: $CODESIGN_IDENTITY"
fi

echo "Built $APP"
