# Skillui

A macOS menu-bar app that gives you one unified, cross-agent view of every
[skills.sh](https://skills.sh) skill you've installed — across Claude Code, Codex,
Cursor, and ~20 other agents — and tells you which ones have an upstream update.

<img src="docs/panel.png" width="380" alt="Skillui panel">

## What it does

- **Discovers** every skill — global, plus across all your projects — via the `skills` CLI (the
  menu-bar panel) and a recursive dev-folder scan (the dashboard).
- **Detects updates** by comparing global lock tree-SHAs against GitHub; project-local root
  `SKILL.md` locks are checked with the same single-file hash as the `skills` CLI.
- **Updates in one click** (`skills update`), with an "Update all".
- **Dashboard window**: every skill across every project in a sortable, filterable table, each tagged
  **Local / Linked / Global / External** so you see at a glance whether a project's skill is its own
  copy or a symlink into the global install. Git worktrees are grouped under their main repo
  (`repo › worktree`). Filter by project, scope, link type, or pending updates.
- **Links out** — click a row for its skills.sh page, the glyph for its GitHub repo.
- Lives in the menu bar (no Dock icon), launches at login, refreshes in the background.

**Privacy**: the project scan only looks in dev folders (`~/workspace`, `~/Developer`, `~/code`, …) and
**never touches Documents, Desktop, Downloads, Music, Pictures**, or other protected folders — so it
won't set off macOS privacy prompts. Point it at a custom root in Settings if your code lives elsewhere.

No account, no database, no third-party dependencies. The only thing it persists is a
small JSON update-cache (so badges survive relaunch and GitHub isn't hammered).

## Requirements

- macOS 26+ (SwiftUI Liquid Glass baseline)
- Node (`npx`) on your login shell, or the `skills` binary — Skillui resolves it for you.
- Optional: a GitHub PAT (Settings) to raise the update-check rate limit 60 → 5000/hr.

## Build & run

```bash
scripts/build-app.sh        # release build → dist/Skillui.app (Developer ID if available)
open dist/Skillui.app
```

Dev verification hooks (headless, no GUI):

```bash
.build/debug/Skillui --scan-dump --check          # global+manual discovery + update status
.build/debug/Skillui --scan-projects [root] --check   # recursive multi-project scan + status
.build/debug/Skillui --render-png panel.png       # rasterize the panel to a PNG
.build/debug/Skillui --dashboard                  # launch with the dashboard window open
```

## Package a DMG

```bash
scripts/make-dmg.sh                          # ad-hoc dist/Skillui-<version>.dmg
DEVELOPER_ID="Developer ID Application: …" \
NOTARY_PROFILE="skillui-notary" scripts/make-dmg.sh   # signed + notarized
```

> Not App Store: Skillui shells out to a CLI and reads arbitrary paths, which the
> sandbox forbids. Distribution is via signed + notarized DMG.

## App updates

Skillui checks GitHub Releases for newer signed DMGs. Use **Check for Updates...** from the app menu,
Settings, or the menu-bar panel footer. When an update exists, Skillui shows a native Software Update
window with the release notes, then downloads and opens the DMG.

This stays system-framework-only: Skillui does not silently replace itself. The release repository is
compiled into `Info.plist` via `SkilluiReleaseRepository` and can be overridden during builds with
`SKILLUI_RELEASE_REPO=owner/repo`.

## Release process

Releases are tag-driven:

```bash
scripts/release.sh 0.1.0
git tag -a v0.1.0 -m "Skillui 0.1.0"
git push origin v0.1.0
```

The GitHub workflow runs tests, builds a DMG, notarizes it, extracts the matching `CHANGELOG.md`
section, and uploads the DMG plus `.sha256` checksum to GitHub Releases. See [docs/release.md](docs/release.md).

## How it works (verified against `skills` CLI v1.5.13)

| Concern | Reality |
|---------|---------|
| Discovery | `skills list -g\|-p --json` → `[{name, path, scope, agents[]}]`. Default scope is project; Skillui queries both. |
| Provenance | Global lock `~/.agents/.skill-lock.json` (rich, has `skillFolderHash` = git tree SHA). Project lock `<root>/skills-lock.json` (lean, `computedHash`). Joined to the list **by name**. |
| Update check | Global locks: `GET /repos/{repo}/git/trees/{defaultBranch}?recursive=1`, compare the folder tree SHA to `skillFolderHash`. Project v1 root `SKILL.md` locks: fetch the upstream file and hash `SKILL.md + contents` to match the CLI's `computedHash`. |
| Cross-agent | A skill in the shared `.agents/skills` dir belongs to many agents at once — shown as agent chips on a single row, never duplicated. |

## Limitations (MVP)

- Update detection: global skills compare the lockfile's git tree-SHA; project-local root
  `SKILL.md` skills compare the lockfile's CLI hash to the upstream file hash. More complex
  project v1 locks do not have a reliable upstream hash, so Skillui does not show false update
  badges for them. Skills not installed from a known source still show as *untracked*.
- The multi-project scan runs in the background; globals show first.
- The GitHub PAT lives in the Keychain; everything else is UserDefaults.
- Application self-update is a GitHub Releases DMG prompt, not a silent in-place updater.
