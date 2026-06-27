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
echo "Publish — pick the path for your setup (see the release-skillui skill / docs/release.md):"
echo "  • CI (Apple signing secrets configured in the repo):"
echo "      git tag -a $TAG -m 'Skillui $VERSION' && git push origin $TAG"
echo "      → release.yml builds, signs, notarizes, and publishes."
echo "  • Local (no secrets — what this script just built):"
echo "      gh release create $TAG --target \$(git rev-parse HEAD) \\"
echo "        --title 'Skillui $VERSION'$([[ "$TAG" == *-* ]] && echo ' --prerelease') \\"
echo "        '$DMG' '$DMG.sha256'"
echo
echo "release.yml gates on APPLE_CERTIFICATE: with no secrets, the tag's CI run skips cleanly."
