---
name: release-skillui
description: Cut, sign, notarize, and publish a complete Skillui macOS release from A to Z. Use when preparing a new public or prerelease version — bumping CHANGELOG.md and Info.plist, running Swift tests, building the signed/notarized DMG + checksum, tagging, publishing the GitHub Release with notes and assets, and smoke-testing the in-app updater. Produces a deterministic release that always has the same shape.
---

# Release Skillui

Drive a full Skillui release end to end. The release **shape is deterministic**: every release
produced by this skill has the identical tag scheme, title, notes source, and asset names,
whether published by CI or locally. Do not improvise the format — follow the template below
exactly. It is the same contract enforced by `.github/workflows/release.yml`; that workflow and
this skill must never diverge.

## Canonical Release Template (do not deviate)

| Field          | Value                                                              |
|----------------|-------------------------------------------------------------------|
| Version        | `<version>` — semver, e.g. `0.2.0` or `0.2.0-beta.1`              |
| Git tag        | `v<version>` (annotated)                                           |
| Release title  | `Skillui <version>`                                                |
| Prerelease     | `true` iff the tag contains `-` (e.g. `-beta.1`), else `false`    |
| Release notes  | the `## v<version>` section of `CHANGELOG.md`, verbatim           |
| Assets         | `Skillui-<version>.dmg` and `Skillui-<version>.dmg.sha256`        |
| Target repo    | `Info.plist` → `SkilluiReleaseRepository` (currently `neogenz/skillui`) |

The in-app updater reads `…/releases/latest` and renders the release **notes** to users, so the
`CHANGELOG.md` section is the single source of release text. Write it for humans.

## CHANGELOG entry template (fixed structure)

Every release section uses this exact skeleton so notes always have the same form. Omit a
subsection only if it is genuinely empty; never reorder them.

```markdown
## v<version>

<one-line summary of the release>

### Added
- ...

### Changed
- ...

### Fixed
- ...
```

Keep the newest release directly under the top `## Unreleased` section. At release time, move the
accumulated `Unreleased` bullets into the new `## v<version>` section (leaving `Unreleased`
present but empty for the next cycle).

## Preconditions (verify before doing anything)

1. Working tree is clean and on the intended release commit (`git status`).
2. A git remote exists and points at the target repo, and `gh` is authed for an account with
   push/release rights to it:
   - `git remote -v` (must resolve to `SkilluiReleaseRepository`)
   - `gh auth status` — confirm the active account can write to that repo.
3. `Info.plist` → `CFBundleShortVersionString` equals `<version>`; bump it if not.
4. `assets/AppIcon.icns` exists.
5. `CHANGELOG.md` has the `## v<version>` section per the template above.

If a remote is missing or the `gh` account cannot write the target repo, STOP and surface that —
publishing cannot succeed until it is fixed. Do not invent a remote.

## Release procedure (A → Z)

Run from the repo root. Set the version once:

```bash
VERSION=0.2.0            # change me; no leading 'v'
TAG="v$VERSION"
```

### 1. Bump metadata
- Edit `CHANGELOG.md`: create the `## v$VERSION` section from the template, moving `Unreleased`
  bullets into it.
- Set `Info.plist` `CFBundleShortVersionString` to `$VERSION`:
  ```bash
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
  ```

### 2. Preflight (tests + signed/notarized DMG + checksum)
Use the local preflight, which runs tests and builds the DMG. For a **publishable** build the
DMG must be signed + notarized, so export the signing env first (one-time setup in
`docs/release.md` → "One-Time Local Signing Setup"):

```bash
export DEVELOPER_ID="Developer ID Application: <Your Name> (<TEAMID>)"
export NOTARY_PROFILE="skillui-notary"
export SKILLUI_VERSION="$VERSION"
export SKILLUI_BUILD="$(git rev-list --count HEAD)"   # parity with CI build number
scripts/release.sh "$VERSION"
```

`scripts/release.sh` verifies the changelog entry, runs `swift test`, builds
`dist/Skillui-$VERSION.dmg`, and writes `dist/Skillui-$VERSION.dmg.sha256`. It does NOT tag,
push, or upload.

Verify the artifact before publishing — the app inside is the verdict that matters:

```bash
spctl -a -t exec -vv dist/Skillui.app                 # → accepted / source=Notarized Developer ID
xcrun stapler validate "dist/Skillui-$VERSION.dmg"    # → The validate action worked!
```

(`spctl` on the bare `.dmg` reporting "no usable signature" is expected and harmless.)

### 3. Commit, tag
```bash
git add CHANGELOG.md Info.plist
git commit -m "release: Skillui $VERSION"
git tag -a "$TAG" -m "Skillui $VERSION"
```

### 4. Publish — pick ONE path; both produce the identical template

**Path A — CI (canonical, preferred).** Push the tag; `release.yml` rebuilds, signs, notarizes,
extracts the changelog section, and publishes the Release with both assets. Requires the repo
signing secrets (listed below) to be set.

```bash
git push origin main          # or the release branch
git push origin "$TAG"
gh run watch                  # follow the Release workflow to green
```

**Path B — local direct publish.** Use the DMG you just notarized in step 2 and publish with
`gh`, matching the template exactly. Use this when CI secrets are absent or you want to ship from
this Mac.

```bash
git push origin "$TAG"        # the release still needs the tag on the remote
# extract the notes for THIS version, same awk contract as release.yml:
awk -v tag="## $TAG" '
  $0 == tag { capture=1; next }
  capture && /^## v/ { exit }
  capture { print }
' CHANGELOG.md > dist/release-notes.md
[ -s dist/release-notes.md ] || { echo "empty release notes for $TAG" >&2; exit 1; }

PRERELEASE=""; [[ "$TAG" == *-* ]] && PRERELEASE="--prerelease"
gh release create "$TAG" \
  --title "Skillui $VERSION" \
  --notes-file dist/release-notes.md \
  $PRERELEASE \
  "dist/Skillui-$VERSION.dmg" \
  "dist/Skillui-$VERSION.dmg.sha256"
```

### 5. Verify the published release
```bash
gh release view "$TAG"        # title "Skillui <version>", correct prerelease flag, 2 assets
```
Confirm both `Skillui-$VERSION.dmg` and `…dmg.sha256` are attached and the notes match the
changelog section.

### 6. Smoke-test the updater
From a previously installed older version, run **Check for Updates…**. Confirm the Software
Update window shows the release notes and downloads/opens the DMG.

## CI signing secrets (Path A only)

`release.yml` requires these repository secrets:

- `APPLE_CERTIFICATE` — base64 Developer ID Application `.p12`
- `APPLE_CERTIFICATE_PASSWORD` — password for the `.p12`
- `NOTARY_APPLE_ID` — Apple ID used for notarization
- `NOTARY_APP_PASSWORD` — app-specific password
- `NOTARY_TEAM_ID` — Apple Developer Team ID

Never publish an unsigned public release. Ad-hoc DMGs (no `DEVELOPER_ID`) are for local dev
smoke tests only.

## Rollback

If a release is wrong, delete it and the tag, fix, and re-run:

```bash
gh release delete "$TAG" --yes
git push origin ":refs/tags/$TAG"
git tag -d "$TAG"
```
