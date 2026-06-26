# Quiver

macOS menu-bar app: one unified, cross-agent view of installed [skills.sh](https://skills.sh)
skills (Claude Code / Codex / Cursor / ~25 agents) with upstream update detection and one-click update.
Swift 6 + SwiftUI, SwiftPM (no `.xcodeproj`), **system frameworks only — no third-party deps**.

## Build / run / test

```bash
swift build                      # debug
swift test                       # unit tests (Swift Testing) — run before committing
scripts/build-app.sh [debug|release]   # → dist/Quiver.app (ad-hoc signed bundle)
scripts/make-dmg.sh              # DMG; set DEVELOPER_ID + NOTARY_PROFILE to notarize
open dist/Quiver.app             # launch the real menu-bar app
```

The app needs the `.app` bundle to behave correctly (MenuBarExtra + `SMAppService`). Running the
bare `.build/.../Quiver` binary works only for the headless hooks below.

## Headless dev hooks (verify without the GUI)

```bash
.build/debug/Quiver --scan-dump [--check]      # print discovered skills (+ update status)
.build/debug/Quiver --render-png <path> [--dark]   # rasterize the panel to PNG (ImageRenderer)
.build/debug/Quiver --render-settings <path>       # rasterize Settings
.build/debug/Quiver --login-status|--login-register|--login-unregister   # test SMAppService (from the bundle)
```

These exit before the GUI starts (see `System/DebugCLI.swift`, `System/RenderCLI.swift`).

## Architecture

`Discovery/` shells out (`skills list`) + reads lockfiles → `[Skill]`. `Updates/` compares folder
tree SHAs against GitHub. `System/AppState.swift` (`@MainActor @Observable`) coordinates everything.
`UI/` is the panel. `App/QuiverApp.swift` is the `@main` MenuBarExtra entry.

- Discovery is **CLI-driven**, never dir-scanning — the `skills` CLI owns the agent↔dir mapping.
- The only persisted state besides UserDefaults/Keychain is `~/Library/Application Support/Quiver/update-cache.json`.

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
- Update detection: `GET /repos/{repo}/git/trees/{defaultBranch}?recursive=1`, match the entry whose
  `path` == the skill folder & `type == "tree"`, compare its `sha` to `skillFolderHash`. Lockfiles
  usually omit `ref` → resolve the default branch. Only skills with a `skillFolderHash` are
  checkable; `computedHash`-only and untracked skills degrade gracefully.
- skills.sh page URL is `https://skills.sh/{source}` (NOT `/skills/{source}`). GitHub repo =
  `sourceUrl` minus `.git`.
- Never run `skills update` to *check* — it mutates. Detection is GitHub-tree-SHA only.

## Conventions

- Swift 6 strict concurrency. `AppState` is `@MainActor @Observable`; models are value types + `Sendable`.
- **Mutating ops (refresh/updateSkill/updateAll) go through `AppState.serialize`** — one serial chain.
  Don't add a path that mutates `skills`/`statuses` concurrently.
- UI surfaces use **semantic system colors** (`Theme.traySurface` = `.textBackgroundColor`, cards =
  `.fill.quaternary`, borderless) so light/dark adapt automatically. Spacing/Radius live in `Theme`.
- GitHub PAT in Keychain (`System/Keychain.swift`), never UserDefaults.

## Gotchas (cost real debugging time)

- **ScrollView collapses to zero height in a self-sizing `MenuBarExtra(.window)`.** `PanelView`
  measures content (`ContentHeightKey`) and sizes the scroll area to it, capped. ImageRenderer can't
  rasterize ScrollView/Form, so `--render-png` uses a non-scroll path (`PanelView(scrollable:false)`)
  — a render looking right does NOT prove the live panel; verify on-device too.
- `SMAppService` login-item registration only works from the **bundle**, not `swift run`.
- Unauthenticated GitHub = 60 req/hr. Update checks are grouped **per repo** (one tree fetch covers
  all its skill folders) + ETag + 6h TTL; keep it that way.
- The app works fully offline except update badges (only GitHub must be reachable).
