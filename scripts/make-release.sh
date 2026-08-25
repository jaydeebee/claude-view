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
# Every tag here is v-prefixed, so passing the version as it appears in
# `git tag` is the obvious mistake. It used to be a silent one: the
# bundle was stamped "v0.3.2", which the app's own update check cannot
# parse, so the shipped build would never see another update.
VERSION="${VERSION#[vV]}"
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "error: version must be dotted numeric, got '${1}'" >&2
    exit 1
fi
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
