#!/usr/bin/env bash
# Local release preflight. This validates the same contract the GitHub release
# workflow expects: changelog entry, tests, release bundle, DMG, and checksum.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: scripts/release.sh <version>   # example: scripts/release.sh 0.1.0" >&2
    exit 2
fi

TAG="v$VERSION"
grep -q "## $TAG" CHANGELOG.md || {
    echo "CHANGELOG.md is missing a '$TAG' section." >&2
    exit 1
}

echo "▸ swift test"
swift test

echo "▸ build DMG"
SKILLUI_VERSION="$VERSION" scripts/make-dmg.sh

DMG="dist/Skillui-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "Missing $DMG" >&2; exit 1; }
[[ -f "$DMG.sha256" ]] || { echo "Missing $DMG.sha256" >&2; exit 1; }

echo
echo "Release preflight complete:"
echo "  $DMG"
echo "  $DMG.sha256"
echo
echo "Tag and publish:"
echo "  git tag -a $TAG -m 'Skillui $VERSION'"
echo "  git push origin $TAG"
echo
echo "GitHub Actions will publish the DMG to GitHub Releases."
