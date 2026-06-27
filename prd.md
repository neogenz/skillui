# Skillui — Product Requirements (MVP)

## Problem

Agent skills from [skills.sh](https://skills.sh) get installed across many tools (Claude Code, Codex,
Cursor, ~25 agents) and many places (global config dirs, individual projects, git worktrees). There's
no single view of what's installed where, which copies are shared vs project-owned, or which have an
upstream update. Checking and updating is manual, per-tool, and easy to forget.

## Target user

A developer who installs skills via the `skills` CLI across several agents and projects on macOS, and
wants a glanceable, trustworthy way to see and maintain them.

## Goals / success criteria

- See every installed skill — global and across all projects — in one place.
- Know, per skill, whether it's a real project-local copy or a symlink into the global install.
- Know which skills have an upstream update, and apply it in one click.
- Zero configuration to start; no account; works offline except the GitHub update check.
- Respect privacy: never touch personal/protected folders, never surprise the user with prompts.

## MVP scope

### In
- **Menu-bar panel**: global skills + watched project folders, grouped, with version (short SHA),
  update badge, agent chips, one-click Update + Update-all, links to skills.sh and GitHub.
- **Dashboard window**: recursive scan of dev folders → every project's skills in a sortable,
  filterable table.
  - **Link type** per skill: Local (real dir) / Linked (symlink into global) / Global / External.
  - **Git worktrees** grouped under their main repo (`repo › worktree`).
  - Filters: project, scope, link type, pending updates; full-text filter; per-cell tooltips.
- **Update detection** (GitHub folder tree-SHA): global skills from the lockfile hash; project-local
  skills by computing the folder's git tree-SHA on disk and comparing to upstream.
- **One-click update** via `skills update`, with immediate feedback even while another runs.
- **System**: menu-bar-only (no Dock icon), launch-at-login, background refresh, Settings
  (scan root, global root, CLI path, GitHub PAT, refresh interval, per-agent visibility, project folders).
- **Application updates**: manual and background GitHub Releases checks, native Software Update window,
  release notes, and DMG download/open flow.
- **Privacy**: scan defaults to dev roots (`~/workspace`, `~/Developer`, `~/code`, …); hard-excludes
  Documents, Desktop, Downloads, Music, Pictures, Movies, Library — never lists their contents.

### Out (non-goals for MVP)
- Installing or browsing/searching new skills from the registry.
- Uninstalling skills from the UI.
- Editing skill contents or resolving local-vs-upstream diffs.
- Historical/time-series tracking of versions.
- skills.sh enrichment (stars, descriptions, security audit).
- Windows/Linux; App Store distribution.
- Silent self-replacement updater; the MVP keeps system frameworks only and opens the release DMG.

## Tech stack & constraints

- Swift 6 (strict concurrency) + SwiftUI; `MenuBarExtra(.window)` + a `Window` scene for the dashboard.
- SwiftPM only — **no `.xcodeproj`, no third-party dependencies**. System frameworks only:
  Foundation (`Process`, `URLSession`), AppKit, ServiceManagement (`SMAppService`), CryptoKit
  (git tree-SHA), Security (Keychain).
- Shells out to `npx skills` (resolved via the login shell, since GUI apps don't inherit PATH).
- No database: skills re-derived on each scan; only a small JSON update-cache is persisted
  (per-repo tree SHAs/ETags + local-folder tree-SHA cache).
- Not sandboxable (shells out + reads arbitrary project paths) → not App Store.

## Distribution

- Code-signed + notarized DMG (`scripts/make-dmg.sh` with a Developer ID; ad-hoc for local).
- GitHub Releases upload via `.github/workflows/release.yml`; release notes sourced from `CHANGELOG.md`.
- macOS 26+.

## Known limitations

- Update checks hit GitHub's 60 req/hr unauthenticated limit across many repos → a GitHub PAT
  (5000 req/hr) is recommended; rate-limiting is surfaced with a banner + token shortcut.
- Skills not installed from a known source show as untracked (no version/update).
- First multi-project scan hashes every project-local folder (then cached by a metadata signature).
- Project scope in the panel requires adding folders manually; the dashboard auto-discovers them.
