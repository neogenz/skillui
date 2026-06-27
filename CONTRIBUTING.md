# Contributing

Thanks for improving Skillui. This is a native macOS SwiftPM app with no third-party runtime dependencies.

## Local Checks

Run these before opening a PR:

```bash
swift test
scripts/build-app.sh debug
```

For UI smoke checks:

```bash
.build/debug/Skillui --render-png /tmp/skillui-panel.png
.build/debug/Skillui --render-settings /tmp/skillui-settings.png
.build/debug/Skillui --render-dashboard /tmp/skillui-dashboard.png
```

## Code Expectations

- Keep Swift 6 strict-concurrency compatibility.
- Keep the app system-framework-only unless there is a deliberate project decision to change that.
- Do not widen default scans beyond development roots.
- Do not run `skills update` for detection; checks must stay read-only until the user chooses Update.
- Keep user-facing release notes in `CHANGELOG.md`.

## Releases

Use the project skill `.agents/skills/release-skillui` or `scripts/release.sh <version>` for release preflight.
