#!/usr/bin/env bash
# Build a release Quiver.app and package it into a DMG.
#
# Local/dev: produces an ad-hoc-signed DMG (runs on THIS Mac; Gatekeeper will warn on
# other Macs). For distribution, export these first:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="quiver-notary"   # a stored `notarytool` keychain profile
# then re-run — the script signs with hardened runtime, notarizes, and staples.
set -euo pipefail

APP="Quiver"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash scripts/build-app.sh release
APPDIR="$ROOT/dist/$APP.app"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    echo "▸ codesign (Developer ID, hardened runtime)"
    codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APPDIR"
else
    echo "▸ no DEVELOPER_ID set — keeping ad-hoc signature (DMG will NOT be notarized)"
fi

DMG="$ROOT/dist/$APP.dmg"
STAGE="$(mktemp -d)"               # ephemeral; removed by the trap below
trap 'rm -rf "$STAGE"' EXIT        # safe: only the temp staging dir we just created
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "▸ created $DMG"

if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "▸ notarizing (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "▸ notarized + stapled"
else
    echo "▸ skipping notarization (set DEVELOPER_ID + NOTARY_PROFILE to enable)"
fi
