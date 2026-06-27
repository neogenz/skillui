# Skillui

macOS menu-bar app: one unified, cross-agent view of installed [skills.sh](https://skills.sh)
skills (Claude Code / Codex / Cursor / ~25 agents) with upstream update detection and one-click update.
Two surfaces: a glanceable **menu-bar panel** (global + watched projects) and a full **dashboard
window** that recursively scans dev folders for every project's skills, classifying each as
project-local vs symlinked-into-global and grouping git worktrees under their main repo.
Swift 6 + SwiftUI, SwiftPM (no `.xcodeproj`), **system frameworks only — no third-party deps**.

## Build / run / test

```bash
swift build                      # debug
swift test                       # unit tests (Swift Testing) — run before committing
scripts/build-app.sh [debug|release]   # → dist/Skillui.app (ad-hoc signed bundle)
scripts/make-dmg.sh              # DMG; set DEVELOPER_ID + notary credentials to notarize
scripts/release.sh <version>     # release preflight: changelog, tests, DMG, checksum
open dist/Skillui.app             # launch the real menu-bar app
```

The app needs the `.app` bundle to behave correctly (MenuBarExtra + `SMAppService`). Running the
bare `.build/.../Skillui` binary works only for the headless hooks below.

## Headless dev hooks (verify without the GUI)

```bash
.build/debug/Skillui --scan-dump [--check]          # global+manual discovery (+ update status)
.build/debug/Skillui --scan-projects [root] [--check]   # recursive multi-project scan (+ status)
.build/debug/Skillui --tree-sha <folder>            # local git tree SHA of a folder
.build/debug/Skillui --render-png|--render-dashboard|--render-settings <path> [--dark]
.build/debug/Skillui --dashboard                    # launch with the dashboard window open
.build/debug/Skillui --login-status|--login-register|--login-unregister   # test SMAppService (from the bundle)
```

These exit before the GUI starts (see `System/DebugCLI.swift`, `System/RenderCLI.swift`).

## Architecture

`Discovery/` builds `[Skill]` two ways:
- **Panel** path = CLI-driven: `SkillsCLI` runs `skills list` (global + watched project roots) joined
  to lockfiles. The `skills` CLI owns the agent↔dir mapping — don't reinvent it here.
- **Dashboard** path = filesystem-driven: `ProjectFinder` recursively finds project dirs under the
  scan root; `FilesystemScanner` enumerates each project's skill dirs; `LinkClassifier` stats them
  for symlink info the CLI doesn't expose; `GitInfo` detects git worktrees.

`Updates/` compares global lock tree SHAs against GitHub and checks project root `SKILL.md`
locks with the `skills` CLI single-file hash. `System/AppState.swift` (`@MainActor @Observable`)
coordinates scans, update checks, settings. `UI/` = `PanelView` (menu bar) + `DashboardView` (window).
`App/SkilluiApp.swift` = `@main` with MenuBarExtra + Settings + Dashboard `Window` scenes.

- The only persisted state besides UserDefaults/Keychain is
  `~/Library/Application Support/Skillui/update-cache.json` (per-repo tree SHAs/ETags + default branches).
- App self-update is GitHub Releases based: `AppReleaseChecker` reads `/releases/latest`, the UI shows
  release notes in `AppUpdateView`, then downloads/opens the DMG. Do not add Sparkle unless the
  system-framework-only constraint is explicitly changed.

## Dashboard: multi-project scan, link types, worktrees

- **Link type** (`LinkType`, classified by `LinkClassifier`): `global` (the canonical install),
  `linkedGlobal` (a project symlink INTO `~/.agents/skills` — shown with a link icon), `projectLocal`
  (a real dir owned by the project), `linkedExternal` (symlink elsewhere). This is the headline
  cross-project signal.
- **Worktrees**: `GitInfo` reads `.git` — a *file* (`gitdir: …/.git/worktrees/<name>`) means a worktree;
  shown as `mainRepo › worktree` and grouped/filterable under the main repo.
- **Update status per kind**: global → stored `skillFolderHash` vs upstream tree SHA; project-local
  root `SKILL.md` → `computedHash` vs upstream single-file hash; linked-global → mapped to its
  global counterpart; complex project v1 / external / untracked → none.
- **Privacy (critical)**: the recursive scan defaults to dev roots (`AppState.defaultDevRoots()`:
  `~/workspace`, `~/Developer`, `~/code`, …), NOT the whole home, and `ProjectFinder.skip` hard-excludes
  macOS TCC-protected/personal dirs (Documents, Desktop, Downloads, Music, Pictures, Movies, Library) so
  the app never lists their contents → no privacy prompts. Never widen this without reason.

## Verified data layer (do NOT re-derive — confirmed against `skills` CLI v1.5.13)

- **No bare `skills` binary** here; invoke via `npx skills`. GUI apps don't inherit the shell PATH,
  so resolve binaries through a login shell (`ShellEnvironment`).
- `skills list --json` → `[{name, path, scope, agents[]}]`. **Default scope is project**; pass `-g`
  (global) / `-p` (project). One skill in the shared `.agents/skills` dir reports **many agents**.
- **Global lock**: `~/.agents/.skill-lock.json` (v3) — rich: `source, sourceUrl, skillPath,
  skillFolderHash` (git tree SHA), timestamps. **Project lock**: `<root>/skills-lock.json` (v1) —
  lean: `computedHash` (sha256, NOT a tree SHA). Both are **keyed maps by skill name**. Join to the
  list by name. (XDG override: `$XDG_STATE_HOME/skills/.skill-lock.json` — matches the CLI source.)
- `skillPath` points at **SKILL.md**; the repo folder is its parent (`""` = repo root).
- Update detection: **Global** skills use `GET /repos/{repo}/git/trees/{defaultBranch}?recursive=1`,
  match the entry whose `path` == the skill folder & `type == "tree"`, and compare its `sha` to
  stored `skillFolderHash`. Lockfiles usually omit `ref` → resolve the default branch.
  **Project v1 root `SKILL.md`** skills fetch the upstream file and compare `computedHash` to the
  CLI-compatible `sha256("SKILL.md" + contents)`. Do **not** compare project `computedHash` to a
  Git tree SHA: root repos include non-installed files and symlinked/expanded folders can produce
  permanent false positives. Complex project v1 skills without `skillFolderHash` are unsupported
  for update checks unless the lock schema gets richer.
- skills.sh page URL is `https://skills.sh/{source}` (NOT `/skills/{source}`). GitHub repo =
  `sourceUrl` minus `.git`.
- Never run `skills update` to *check* — it mutates. Even `skills update --help` mutates with
  skills@1.5.13, so help text must not be probed through the update subcommand.

## Conventions

- Swift 6 strict concurrency. `AppState` is `@MainActor @Observable`; models are value types + `Sendable`.
- **Mutating ops (refresh/updateSkill/updateAll) go through `AppState.serialize`** — one serial chain.
  Don't add a path that mutates `skills`/`statuses` concurrently.
- UI surfaces use **semantic system colors** (`Theme.traySurface` = `.textBackgroundColor`, cards =
  `.fill.quaternary`, borderless) so light/dark adapt automatically. Spacing/Radius live in `Theme`.
- GitHub PAT in Keychain (`System/Keychain.swift`), never UserDefaults.
- Release notes live in `CHANGELOG.md`; GitHub Releases should upload `Skillui-<version>.dmg` plus
  `.sha256`, and the release body should be the matching changelog section because the updater displays it.

## Gotchas (cost real debugging time)

- **ScrollView collapses to zero height in a self-sizing `MenuBarExtra(.window)`.** `PanelView`
  measures content (`ContentHeightKey`) and sizes the scroll area to it, capped. ImageRenderer can't
  rasterize ScrollView/Form, so `--render-png` uses a non-scroll path (`PanelView(scrollable:false)`)
  — a render looking right does NOT prove the live panel; verify on-device too.
- `SMAppService` login-item registration only works from the **bundle**, not `swift run`.
- Unauthenticated GitHub = 60 req/hr. Update checks are grouped **per repo** (one tree fetch covers
  all its skill folders) + ETag + 6h TTL; keep it that way. Many project repos still blow 60/hr → a
  PAT (5000/hr) is needed; rate-limit (403) is surfaced as a dashboard banner (`AppState.isRateLimited`)
  with an "Add token" button that opens Settings focused on the PAT field.
- Recursive project scans run in the background — globals/panel show first; `.checking` shows while
  comparable project roots are evaluated.
- The app works fully offline except update badges (only GitHub must be reachable).
- Public releases need Developer ID signing + notarization. In CI use
  `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_APP_PASSWORD`,
  and `NOTARY_TEAM_ID`; local releases may use `NOTARY_PROFILE`.
