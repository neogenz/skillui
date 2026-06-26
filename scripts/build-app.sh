#!/usr/bin/env bash
# Build Quiver and assemble a runnable .app bundle.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

APP="Quiver"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"

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

# Ad-hoc signature: sufficient for local launch + SMAppService during development.
# Real distribution needs a Developer ID identity + notarization (see make-dmg.sh).
codesign --force --deep --sign - "$APPDIR" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "▸ built $APPDIR"
