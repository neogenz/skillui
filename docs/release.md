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

```bash
git tag -a v0.1.0 -m "Skillui 0.1.0"
git push origin v0.1.0
```

The Release workflow runs tests, builds the DMG, notarizes it, extracts the matching changelog section, and uploads the DMG plus checksum to GitHub Releases.

## Update Flow

The app checks `https://api.github.com/repos/<owner>/<repo>/releases/latest`. If the latest stable release is newer than `CFBundleShortVersionString`, Skillui shows a native Software Update window with the GitHub release notes and downloads the `.dmg` asset to Downloads.

This is not silent self-replacement. Users still mount the DMG and replace the app, which keeps the project system-framework-only.
