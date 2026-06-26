# Quiver — Build Progress

Menu-bar app: unified cross-agent view of skills.sh-installed skills, with update detection.

## Runtime facts verified (analysis) — these CORRECT the original spec

| Topic | Verified truth |
|-------|----------------|
| `skills` binary | NOT on PATH — invoke via `npx skills` (resolve `npx` through login shell) |
| `skills list` scope | default = **project**; need `-g` (global) / `-p` (project). Returns `[{name, path, scope, agents[]}]` |
| `agents` field | display names; one shared `.agents/skills` skill → **many agents** (don't group-by-agent) |
| Global lock | `~/.agents/.skill-lock.json` (v3) — `{version, skills:{name:{source,sourceUrl,skillPath,skillFolderHash,installedAt,updatedAt}}, dismissed}` |
| Project lock | `<root>/skills-lock.json` (v1) — leaner, uses `computedHash` (sha256), no tree SHA |
| `skillPath` | points at **SKILL.md** → repo folder = its parent dir |
| `ref` | usually absent → resolve repo default branch |
| Update detection | GET `repos/{repo}/git/trees/{defaultBranch}?recursive=1`, match `path==folder & type==tree`, compare `sha` vs `skillFolderHash`. **Proven** against real data (find-skills → update available) |
| skills.sh URL | `https://skills.sh/{source}` (NOT `/skills/{source}`) |
| Toolchain | Xcode 26.5, Swift 6.3.2 ✓ |

## Tasks

- [x] **0. Analyze** — verified both VERIFY items + corrected ~6 spec assumptions; proved update algorithm end-to-end.
- [x] **1-2. Scaffold + menu-bar shell** — verified: launches as UIElement (no Dock), MenuBarExtra(.window).
- [x] **3-4. Discovery** — ShellEnvironment, SkillsCLI, LockfileParser (both schemas), SkillScanner. Verified: `--scan-dump` loads 40 real skills, tracked ones carry source/folder/SHA, untracked skipped.
- [x] **5. Update detection** — GitHubClient + UpdateChecker + UpdateCache (ETag, 6h). Verified: find-skills/angular-developer/modern-web-guidance→updateAvailable, slidev→upToDate via real tree-SHA. Headless via `--scan-dump --check`.
- [x] **6. Panel UI** — sectioned cards, version chips, amber dots, agent chips, collapsible untracked. Verified via ImageRenderer PNG.
- [x] **7. Actions + links** — update/update-all/skills.sh/GitHub. Verified: real update of find-skills flipped badge to up-to-date (3→2 updates).
- [x] **8. System** — Keychain PAT, SMAppService login item (register→enabled→unregister verified), 6h background refresh (unattended scan verified), Settings form.
- [x] **9. States + dist** — empty/cli-missing/offline states; make-dmg.sh (ad-hoc + Developer-ID/notarize gated on env); README. Release build clean (0 warnings).

## Assumptions
- Project scope requires user-added folders in Settings (CLI can't enumerate projects); **global is primary**.
- PAT stored in Keychain.
- `build-app.sh` overwrites bundle files in place (no recursive delete).
- Notarization/Developer-ID signing is scripted but not executed here (no cert).
