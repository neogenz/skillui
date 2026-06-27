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
| Prerelease     | `true` iff the tag contains `-` (e.g. `-beta.1`), else `false`. Pre-releases are NOT offered by the in-app updater — see the note below. |
| Release notes  | the `## v<version>` section of `CHANGELOG.md`, verbatim           |
| Assets         | `Skillui-<version>.dmg` and `Skillui-<version>.dmg.sha256`        |
| Target repo    | `Info.plist` → `SkilluiReleaseRepository` (currently `neogenz/skillui`) |

### Stable vs pre-release — what the in-app updater sees

The in-app updater (`AppReleaseChecker`, `Sources/Skillui/Updates/AppReleaseChecker.swift`)
queries `GET /releases/latest`, which GitHub resolves to the newest **non-prerelease** release.
Two consequences follow, and they decide the tag you choose:

- A **stable** release (no `-` in the tag, `prerelease=false`) is the one **"Check for Updates"
  offers to users**, and the matching `## v<version>` section of `CHANGELOG.md` is the single
  source of the notes it renders — so write that section for humans.
- A **pre-release** (any tag with `-`, e.g. `v0.1.0-beta.1`, `prerelease=true`) is deliberately
  **invisible to the updater**: `/releases/latest` skips it, so no installed app is ever
  auto-offered the beta. Its DMG is still downloadable from the Releases page — it just isn't
  pushed to users.

So: ship a **stable** release when you want every user updated; ship a **pre-release** for betas
you want available for manual download but not auto-installed. (To make pre-releases
discoverable in-app you'd have to change the checker to read `/releases` instead of
`/releases/latest` — that is a deliberate code change, not the default.)

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

### 3. Commit + pin the target
```bash
git add CHANGELOG.md            # + Info.plist only if you bumped CFBundleShortVersionString
git commit -m "release: Skillui $VERSION"
REL_SHA=$(git rev-parse HEAD)   # pin the release to this exact commit (safe under parallel work)
```
The tag is created by your chosen publish path below — not here — so it always lands on `$REL_SHA`.

### 4. Publish — choose the path by whether CI signing secrets are set

Creating the tag (either path) triggers `.github/workflows/release.yml`. That workflow **gates on
the `APPLE_CERTIFICATE` secret**: with the signing secrets set it builds + publishes; without them
the build job is **skipped cleanly** (no failed run). The two paths are therefore mutually
exclusive — pick by configuration, never run both:

- **Secrets configured → Path A (CI).** Don't build locally; push the tag and let CI publish.
- **Secrets absent → Path B (local).** Build + notarize here (steps 2–3), publish with `gh`; CI
  sees the tag and skips.

Both paths produce the identical release template.

**Path A — CI.** Push the tag; `release.yml` rebuilds, signs, notarizes, extracts the changelog
section, and publishes the Release with both assets. Requires the repo signing secrets (listed
below). Do NOT also run Path B for the same tag.

```bash
git push origin main
git tag -a "$TAG" -m "Skillui $VERSION"
git push origin "$TAG"        # triggers release.yml → CI builds, signs, notarizes, publishes
gh run watch                  # follow the Release workflow to green
```

**Path B — local direct publish.** Use when CI secrets are absent (CI will skip on the tag).
Publish the DMG you notarized in steps 2–3 with `gh`, matching the template exactly. Pin the
release to the exact commit with `--target "$REL_SHA"` (capture `REL_SHA=$(git rev-parse HEAD)`
after the release commit) so it doesn't drift if `main` advances.

```bash
git push origin main          # the release commit must be on the remote for --target
# extract the notes for THIS version, same awk contract as release.yml:
awk -v tag="## $TAG" '
  $0 == tag { capture=1; next }
  capture && /^## v/ { exit }
  capture { print }
' CHANGELOG.md > dist/release-notes.md
[ -s dist/release-notes.md ] || { echo "empty release notes for $TAG" >&2; exit 1; }

PRERELEASE=""; [[ "$TAG" == *-* ]] && PRERELEASE="--prerelease"
gh release create "$TAG" \
  --target "$REL_SHA" \         # gh creates the tag at this commit (CI gate skips: no secrets)
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
