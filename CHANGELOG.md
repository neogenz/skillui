# Changelog

All notable changes to Skillui are documented here. Keep the newest release first and write notes for humans; GitHub Release notes are what the in-app updater shows.

## Unreleased

## v0.1.0-beta.1

First public beta of Skillui: a glanceable menu-bar panel plus a full dashboard that give one
unified, cross-agent view of installed [skills.sh](https://skills.sh) skills (Claude Code,
Codex, Cursor, and ~25 agents), with upstream update detection and one-click update. Shipped as
a signed + notarized DMG.

### Added

- Unified macOS menu-bar panel for skills.sh-installed skills across global and project scopes.
- Dashboard that recursively scans dev folders and classifies each skill as project-local,
  linked-global, linked-external, or global, grouping git worktrees under their main repo.
- GitHub tree-SHA update detection with ETag caching and a 6h TTL; per-skill update and update-all.
- Update activity window with step-by-step tracking of update/install runs.
- Explicit GitHub PAT authorization stored in the Keychain, with credential status in Settings
  (raises the unauthenticated 60 req/hr GitHub limit to 5000).
- Worktree gap detection for projects whose lockfile declares skills that aren't installed,
  with one-click reinstall.
- GitHub Releases-based application self-update with a native Software Update window.
- Generated macOS app icon and bundle icon resources.

### Changed

- Renamed the app from Quiver to Skillui.
