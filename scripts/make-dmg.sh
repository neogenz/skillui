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
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APPDIR"
else
    echo "▸ no DEVELOPER_ID set — keeping ad-hoc signature (DMG will NOT be notarized)"
fi

DMG="$ROOT/dist/$APP-$VERSION.dmg"
STAGE="$(mktemp -d)"               # ephemeral; removed by the trap below
trap 'rm -rf "$STAGE"' EXIT        # safe: only the temp staging dir we just created

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

have_notary_creds() {
    [[ -n "${NOTARY_PROFILE:-}" ]] || \
        { [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_APP_PASSWORD:-}" && -n "${NOTARY_TEAM_ID:-}" ]]; }
}

# Decide notarization ONCE, up front. Distribution needs BOTH a Developer ID identity (for the
# hardened-runtime signature) and notary credentials. The key invariant: credentials that are
# present but fail to notarize are FATAL — we must never fall through and ship an un-notarized DMG
# (the old code collapsed "no creds" and "notarization failed" into one skip + exit 0).
NOTARIZE=false
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "▸ skipping notarization (set DEVELOPER_ID plus NOTARY_PROFILE or NOTARY_APPLE_ID/NOTARY_APP_PASSWORD/NOTARY_TEAM_ID)"
elif ! have_notary_creds; then
    echo "▸ skipping notarization (set NOTARY_PROFILE or NOTARY_APPLE_ID/NOTARY_APP_PASSWORD/NOTARY_TEAM_ID)"
else
    NOTARIZE=true
fi

# Staple the .app BEFORE wrapping it: a UDZO DMG is read-only, so the app inside cannot be stapled
# after `hdiutil create`. Without its own ticket, an app dragged out of the DMG would fall back to
# an online Gatekeeper check and fail on an offline first launch. (Costs a second notary submission.)
if $NOTARIZE; then
    echo "▸ notarizing app (this can take a few minutes)…"
    ditto -c -k --keepParent "$APPDIR" "$STAGE/$APP.zip"
    notarize "$STAGE/$APP.zip" || { echo "✗ app notarization FAILED — refusing to publish" >&2; exit 1; }
    xcrun stapler staple "$APPDIR"
    rm -f "$STAGE/$APP.zip"
    echo "▸ app notarized + stapled"
fi

cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "▸ created $DMG"

if $NOTARIZE; then
    echo "▸ notarizing DMG…"
    notarize "$DMG" || { echo "✗ DMG notarization FAILED — refusing to publish" >&2; exit 1; }
    xcrun stapler staple "$DMG"
    echo "▸ DMG notarized + stapled"
fi

# Checksum the FINAL artifact — stapling (above) rewrites the DMG, so this MUST come after it,
# otherwise the published .sha256 won't match the published DMG. Write a bare filename (run from
# dist/) so `shasum -a 256 -c` verifies wherever the user downloaded the pair.
( cd "$ROOT/dist" && shasum -a 256 "$APP-$VERSION.dmg" > "$APP-$VERSION.dmg.sha256" )
echo "▸ checksum $DMG.sha256"
