# Changelog

All notable changes to Skillui are documented here. Keep the newest release first and write notes for humans; GitHub Release notes are what the in-app updater shows.

## Unreleased

### Added

- GitHub Releases-based application update checks with a native Software Update window.
- Generated macOS app icon and bundle icon resources.
- Release automation for signed/notarized DMG publishing.

### Changed

- Renamed the app from Quiver to Skillui.

## v0.1.0

Initial public release candidate.

### Highlights

- Unified macOS menu-bar panel for skills.sh-installed skills across global and project scopes.
- Dashboard scan for project-local, linked-global, linked-external, and global skills.
- GitHub tree-SHA update detection with ETag caching and Keychain-backed GitHub token support.
- Worktree gap detection for projects whose lockfile declares missing skills.
- Signed/notarized DMG distribution path.
