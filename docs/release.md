# Release Process

Skillui ships outside the Mac App Store because it shells out to local CLI tools and scans developer-selected folders. Public releases are signed, notarized DMGs uploaded to GitHub Releases.

## One-Time GitHub Setup

Add these repository secrets:

- `APPLE_CERTIFICATE`: base64 Developer ID Application `.p12`.
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12`.
- `NOTARY_APPLE_ID`: Apple ID used for notarization.
- `NOTARY_APP_PASSWORD`: app-specific Apple ID password.
- `NOTARY_TEAM_ID`: Apple Developer Team ID.

Set the repository that hosts releases in the build with `SKILLUI_RELEASE_REPO`. The GitHub workflow sets this automatically to `${{ github.repository }}`.

## Repository Protection (rulesets)

A published release must never be silently deleted or force-moved, so the `v*` tags are
**immutable**. Two GitHub rulesets enforce the baseline (configured once; inspect with
`gh api repos/neogenz/skillui/rulesets`):

- **`tag-protection`** (target `tag`, active): pattern `refs/tags/v*`, rules `deletion` +
  `non_fast_forward`, **no bypass actors** — `v*` release tags can't be deleted or force-moved by
  anyone, admins included. This is what makes a published release tamper-evident. Creating a *new*
  tag is unaffected, so normal releases work as usual.
- **`main-protection`** (target `branch`, active): default branch, rules `deletion` +
  `non_fast_forward` — blocks force-push and deletion of `main` while leaving the direct-push
  release flow (`scripts/release.sh` → push `main` → push tag) working.

Recreate them on a fresh repo:

```bash
REPO=neogenz/skillui
gh api -X POST repos/$REPO/rulesets --input - <<'JSON'
{ "name": "tag-protection", "target": "tag", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ {"type":"deletion"}, {"type":"non_fast_forward"} ], "bypass_actors": [] }
JSON
gh api -X POST repos/$REPO/rulesets --input - <<'JSON'
{ "name": "main-protection", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [ {"type":"deletion"}, {"type":"non_fast_forward"} ], "bypass_actors": [] }
JSON
```

Keep secret scanning + push protection + Dependabot on (Settings → Code security, or via API):

```bash
gh api -X PUT repos/$REPO/vulnerability-alerts          # Dependabot alerts
gh api -X PUT repos/$REPO/automated-security-fixes      # Dependabot security updates
```

Because `tag-protection` has **no bypass**, deleting a bad `v*` tag is a deliberate two-step — see
**Rollback** in the `release-skillui` skill.

## One-Time Local Signing Setup

To build a signed + notarized DMG **on your own Mac** (instead of in CI), set this up once.
Requires an active paid Apple Developer Program membership.

1. **Create a Developer ID Application certificate.** Not "Apple Development" and not
   "Distribution Managed" — those cannot notarize for distribution outside the App Store.
   In Xcode → Settings → Accounts → Manage Certificates → `+` → **Developer ID Application**,
   or at <https://developer.apple.com/account/resources/certificates>. Confirm it landed in
   the keychain with its private key:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   # → Developer ID Application: Your Name (TEAMID)
   ```

   That full string is your `DEVELOPER_ID`.

2. **Generate an app-specific password** for notarization at <https://appleid.apple.com>
   → Sign-In and Security → App-Specific Passwords. Format `xxxx-xxxx-xxxx-xxxx`. This is
   **not** your Apple ID password.

3. **Store notarization credentials** in the keychain under a named profile (done once;
   `notarytool` is Apple's official notarization CLI, bundled with Xcode command-line tools):

   ```bash
   xcrun notarytool store-credentials skillui-notary \
     --apple-id "you@example.com" \
     --team-id "TEAMID" \
     --password "xxxx-xxxx-xxxx-xxxx"
   ```

   Validates and saves silently; you reference it later as `--keychain-profile skillui-notary`.

## Build a Signed + Notarized DMG Locally

With the setup above done, point `make-dmg.sh` at the cert and profile:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="skillui-notary" \
scripts/make-dmg.sh
```

The script signs with hardened runtime + timestamp, submits to the Apple notary service
(`--wait`, a few minutes), and staples the ticket to the DMG. Without these env vars it
keeps an ad-hoc signature and skips notarization (dev-only DMG).

Verify the result — the app inside is the verdict that matters:

```bash
spctl -a -t exec -vv dist/Skillui.app     # → accepted / source=Notarized Developer ID
xcrun stapler validate dist/Skillui-<version>.dmg   # → The validate action worked!
```

`spctl` on the bare `.dmg` reports "no usable signature" — that is expected (the DMG is
notarized + stapled but not itself code-signed) and does not block Gatekeeper.

## Local Preflight

```bash
scripts/release.sh 0.1.0
```

The script verifies `CHANGELOG.md`, runs tests, builds `dist/Skillui-<version>.dmg`, and writes `dist/Skillui-<version>.dmg.sha256`.

## Publish

Two mutually exclusive paths — pick by whether the CI signing secrets above are configured. The
`release-skillui` skill drives either one deterministically end to end; the summary:

- **CI (secrets configured).** Push the tag; `release.yml` builds, signs, notarizes, extracts the
  matching changelog section, and uploads the DMG + checksum.

  ```bash
  git tag -a v0.1.0 -m "Skillui 0.1.0"
  git push origin v0.1.0
  ```

- **Local (no secrets).** Build the signed DMG with the flow above, then publish with
  `gh release create`. `release.yml` gates on `APPLE_CERTIFICATE`: when it's absent the tag's
  workflow run is **skipped cleanly** (no failed run), so a locally-published tag never leaves a
  red ❌ in Actions.

Do not run both paths for the same tag.

## Update Flow

The app checks `https://api.github.com/repos/<owner>/<repo>/releases/latest`. If the latest stable release is newer than `CFBundleShortVersionString`, Skillui shows a native Software Update window with the GitHub release notes and downloads the `.dmg` asset to Downloads.

This is not silent self-replacement. Users still mount the DMG and replace the app, which keeps the project system-framework-only.
