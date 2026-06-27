#!/usr/bin/env bash
# Build a release Skillui.app and package it into a DMG.
#
# Local/dev: produces an ad-hoc-signed DMG (runs on THIS Mac; Gatekeeper will warn on
# other Macs). For distribution, export these first:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="skillui-notary"   # a stored `notarytool` keychain profile
# or, in CI:
#   NOTARY_APPLE_ID / NOTARY_APP_PASSWORD / NOTARY_TEAM_ID
# then re-run — the script signs with hardened runtime, notarizes, and staples.
set -euo pipefail

APP="${SKILLUI_APP_NAME:-Skillui}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${SKILLUI_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")}"

bash scripts/build-app.sh release
APPDIR="$ROOT/dist/$APP.app"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "▸ codesign (Developer ID, hardened runtime)"
    codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APPDIR"
else
    echo "▸ no DEVELOPER_ID set — keeping ad-hoc signature (DMG will NOT be notarized)"
fi

DMG="$ROOT/dist/$APP-$VERSION.dmg"
STAGE="$(mktemp -d)"               # ephemeral; removed by the trap below
trap 'rm -rf "$STAGE"' EXIT        # safe: only the temp staging dir we just created
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "▸ created $DMG"

notarize() {
    local artifact="$1"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
    elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_APP_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; then
        xcrun notarytool submit "$artifact" \
            --apple-id "$NOTARY_APPLE_ID" \
            --password "$NOTARY_APP_PASSWORD" \
            --team-id "$NOTARY_TEAM_ID" \
            --wait
    else
        return 1
    fi
}

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "▸ notarizing (this can take a few minutes)…"
    if notarize "$DMG"; then
        xcrun stapler staple "$DMG"
        echo "▸ notarized + stapled"
    else
        echo "▸ skipping notarization (set NOTARY_PROFILE or NOTARY_APPLE_ID/NOTARY_APP_PASSWORD/NOTARY_TEAM_ID)"
    fi
else
    echo "▸ skipping notarization (set DEVELOPER_ID plus NOTARY_PROFILE or NOTARY_APPLE_ID/NOTARY_APP_PASSWORD/NOTARY_TEAM_ID)"
fi

# Checksum the FINAL artifact — stapling (above) rewrites the DMG, so this MUST come after it,
# otherwise the published .sha256 won't match the published DMG. Write a bare filename (run from
# dist/) so `shasum -a 256 -c` verifies wherever the user downloaded the pair.
( cd "$ROOT/dist" && shasum -a 256 "$APP-$VERSION.dmg" > "$APP-$VERSION.dmg.sha256" )
echo "▸ checksum $DMG.sha256"
