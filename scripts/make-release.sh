#!/bin/bash
# Build, sign, notarize, and package a release.
#
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=claude-view-notary \
#   scripts/make-release.sh 0.2.0
#
# One-time notarytool setup:
#   xcrun notarytool store-credentials claude-view-notary \
#       --apple-id you@example.com --team-id TEAMID
#
# Without CODESIGN_IDENTITY the app is unsigned (fine for your own
# machines); without NOTARY_PROFILE notarization is skipped.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: make-release.sh <version>}"
APP="dist/Claude View.app"
ZIP="dist/ClaudeView-${VERSION}.zip"

UNIVERSAL=1 VERSION="$VERSION" scripts/make-app.sh

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${CODESIGN_IDENTITY:-}" ]; then
        echo "error: notarization requires CODESIGN_IDENTITY" >&2
        exit 1
    fi
    echo "Notarizing..."
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm "$ZIP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
echo
echo "Built $ZIP"
echo "Publish with:"
echo "  gh release create v${VERSION} '${ZIP}' --title 'Claude View ${VERSION}' --generate-notes"
