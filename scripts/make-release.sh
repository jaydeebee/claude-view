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

# The artifact path is only ever written by the final packaging step
# below. Notarization submits its own copy under a scratch name and
# removes it either way, so a failed run leaves nothing behind that looks
# like a finished release — the previous version wrote the submission to
# the artifact path itself and deleted it only on success, so a failure
# left a stale, unstapled zip sitting exactly where a shippable one goes.
rm -f "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${CODESIGN_IDENTITY:-}" ]; then
        echo "error: notarization requires CODESIGN_IDENTITY" >&2
        exit 1
    fi
    echo "Notarizing..."
    SUBMISSION="dist/notarize-${VERSION}.zip"
    trap 'rm -f "$SUBMISSION"' EXIT
    ditto -c -k --keepParent "$APP" "$SUBMISSION"
    xcrun notarytool submit "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$SUBMISSION"
    trap - EXIT
fi

ditto -c -k --keepParent "$APP" "$ZIP"
echo
echo "Built $ZIP"

# Publishing instructions belong to a build someone could publish. An
# unsigned local build cannot be, and printing the command anyway invited
# exactly one mistake: shipping a zip that Gatekeeper refuses to open on
# any machine but this one.
if [ -n "${CODESIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "Publish with:"
    echo "  gh release create v${VERSION} '${ZIP}' --title 'Claude View ${VERSION}' --generate-notes"
else
    echo "Unsigned or un-notarized: fine for this machine, not for a release."
    echo "For a publishable build, set CODESIGN_IDENTITY and NOTARY_PROFILE."
fi
