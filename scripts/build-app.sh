#!/usr/bin/env bash
# Build Skillui and assemble a runnable .app bundle.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

APP="${SKILLUI_APP_NAME:-Skillui}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
VERSION="${SKILLUI_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")}"
BUILD="${SKILLUI_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${SKILLUI_BUNDLE_ID:-com.maximedesogus.skillui}"
RELEASE_REPO="${SKILLUI_RELEASE_REPO:-neogenz/skillui}"
CODESIGN_IDENTITY="${SKILLUI_CODESIGN_IDENTITY:-${DEVELOPER_ID:-}}"
if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$CODESIGN_IDENTITY" ]]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
        | head -n 1)"
fi

cd "$ROOT"
echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG"

BINDIR="$(swift build -c "$CONFIG" --show-bin-path)"
APPDIR="$ROOT/dist/$APP.app"
MACOS="$APPDIR/Contents/MacOS"
RES="$APPDIR/Contents/Resources"

# Note: we overwrite files in place rather than recursively deleting the bundle.
# The bundle has a fixed, tiny file set (binary + Info.plist), so no orphans accumulate.
mkdir -p "$MACOS" "$RES"
cp "$BINDIR/$APP" "$MACOS/$APP"
cp "$ROOT/Info.plist" "$APPDIR/Contents/Info.plist"
if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
    cp "$ROOT/assets/AppIcon.icns" "$RES/AppIcon.icns"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $APP" "$APPDIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP" "$APPDIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP" "$APPDIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APPDIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APPDIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APPDIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SkilluiReleaseRepository $RELEASE_REPO" "$APPDIR/Contents/Info.plist"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
    echo "▸ codesign $APP with $CODESIGN_IDENTITY"
    codesign --force --deep --options runtime --sign "$CODESIGN_IDENTITY" "$APPDIR" >/dev/null
else
    # Fallback for contributors without an Apple signing identity. This runs locally but does not
    # provide a stable Keychain access identity across rebuilds.
    echo "▸ codesign $APP ad-hoc"
    codesign --force --deep --sign - "$APPDIR" >/dev/null 2>&1 || echo "  (codesign skipped)"
fi

echo "▸ built $APPDIR ($VERSION/$BUILD)"
