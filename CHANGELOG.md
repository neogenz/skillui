# Changelog

All notable changes to Skillui are documented here. Keep the newest release first and write notes for humans; GitHub Release notes are what the in-app updater shows.

## Unreleased

## v0.1.0-beta.5

Fix stale global skills lingering in the dashboard after they're removed or updated.

### Fixed

- The dashboard's Rescan button now runs a full refresh — re-scanning global skills as well as
  the project tree — instead of only rescanning projects. Previously the global list was loaded
  once at launch and never refreshed from the dashboard window, so a globally removed or updated
  skill kept showing in the Updates view until the app was relaunched. The button's progress
  spinner and disabled state now track both scans.

## v0.1.0-beta.4

Dashboard install experience: a project-scoped install flow, readable activity logs, and honest
handling of skills whose source can't be auto-installed.

### Added

- A focused project with skills declared but not installed now shows a scoped "Install N skills"
  call-to-action — a contextual banner, or the empty-state when nothing is installed yet — instead
  of only the generic cross-project banner, so it's clear the action applies to the folder in focus.
- "Copy path" in the project tree's right-click menu (worktree rows and multi-worktree project rows).

### Changed

- The install activity log is readable now: the `skills` CLI progress spinner is collapsed to its
  final line and terminal control codes are stripped, instead of leaking hundreds of `[999D[J` lines.
- A failed install shows a concise reason (e.g. "Failed to clone …") instead of the full raw dump.
- Installing a project that mixes cloneable and non-git sources no longer aborts on the first bad
  source: each cloneable source installs on its own, so one un-cloneable entry can't block the rest.

### Fixed

- A skill whose lockfile source isn't a git repository (e.g. a bare domain like `likec4.dev`) is
  detected up front, shown with its reason ("source '…' isn't a git repository"), and never offered
  a no-op install button — install counts and buttons act only on skills that can actually be installed.

## v0.1.0-beta.3

Bug-fix beta: installing or scanning skills no longer fails when the app is launched from
Finder/Spotlight (the normal way for a menu-bar app).

### Fixed

- "Install missing skills", scan, and update no longer fail with `env: node: No such file or
  directory`. A GUI app launched from Finder inherits only launchd's stripped `PATH`, so the
  `npx` child (a `#!/usr/bin/env node` script) couldn't find `node`. Skillui now forwards the
  login shell's `PATH` — plus the resolved binary's own directory — to every `skills` CLI
  child, so `node` (and any `git`/`npm`/`pnpm` the CLI shells out to) resolves regardless of
  how the app was launched.

## v0.1.0-beta.2

Maintenance beta from a full code audit: correctness, performance, accessibility, and
release-pipeline fixes. No new features.

### Fixed

- Dashboard project-local update badges no longer blank out after updating a global skill
  (a status map shared with the dashboard was being over-pruned).
- The menu-bar app now tracks its Dock icon correctly across the Dashboard, Software Update,
  and Update Activity windows — it no longer lingers after the last window closes, nor vanishes
  while another window is still open.
- Release packaging fails loudly if notarization fails instead of silently shipping an
  un-notarized DMG, and now staples the ticket to the app as well as the DMG, so an app copied
  out of the DMG still verifies offline.

### Changed

- Faster Dashboard and menu-bar rendering: the skill list is filtered, sorted, and grouped once
  per refresh instead of several times per redraw.
- A cancelled scan now stops its `npx`/`skills` child process immediately instead of leaving it
  running until a timeout.
- Concurrent update checks of the same repository share a single GitHub request, and the update
  cache is written once per check instead of after every entry.
- Settings controls now carry proper accessibility labels.
- Internal: dropped the deprecated `codesign --deep`; the local release preflight validates the
  changelog the same way the CI release workflow does.

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
