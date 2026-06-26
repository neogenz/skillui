import Foundation

/// One entry from a `skills-lock.json` / `.skill-lock.json` file.
///
/// Reality (verified against skills CLI v1.5.13 on-disk):
///   - GLOBAL lock `~/.agents/.skill-lock.json` (version 3) carries the rich schema:
///     `source, sourceType, sourceUrl, skillPath, skillFolderHash, installedAt, updatedAt`.
///     `skillFolderHash` is a 40-hex git *tree* SHA → usable for update detection.
///   - PROJECT lock `<root>/skills-lock.json` (version 1) is leaner:
///     `source, sourceType, skillPath, computedHash` (a sha256 of folder contents).
///     No git tree SHA → cannot be tree-SHA-compared; update check degrades.
///   - Neither stores `ref` reliably → resolve the repo default branch at check time.
///   - `skillPath` points at the SKILL.md file, so the repo *folder* is its parent dir.
struct LockEntry: Sendable, Equatable {
    var source: String? = nil          // "owner/repo"
    var sourceURL: String? = nil       // e.g. "https://github.com/owner/repo.git"
    var ref: String? = nil             // usually absent
    var skillPath: String? = nil       // path to SKILL.md within the repo
    var skillFolderHash: String? = nil // git tree SHA (v3 global) — updatable
    var computedHash: String? = nil    // sha256 of contents (v1 project)
    var pluginName: String? = nil
}

/// Update state for a skill, surfaced as a badge in the UI.
enum UpdateStatus: Sendable, Equatable {
    case unknown          // not checked yet
    case checking
    case upToDate
    case updateAvailable
    case unsupported      // no git tree SHA available (untracked or computedHash-only)
    case failed(String)
}

/// A discovered skill: the merge of one `skills list --json` row with its
/// matching lockfile entry (joined by name within a scope).
struct Skill: Identifiable, Sendable, Equatable {
    let name: String
    let path: String            // absolute install path (canonicalPath from the CLI)
    let scope: Scope
    let agents: [String]        // display names, e.g. ["Claude Code","Cursor",…]
    let projectPath: String?    // project root for project-scope skills; nil for global
    var lock: LockEntry?
    var linkType: LinkType = .global   // set by the scanners (global / linked / project-local)
    var projectGroup: String? = nil    // main repo name (worktrees grouped under it); nil for global
    var isWorktree: Bool = false       // project is a git worktree of `projectGroup`

    var id: String { "\(scope.rawValue)|\(projectPath ?? "~")|\(name)|\(path)" }

    /// Short project label for the dashboard (last path component of the project root).
    var projectName: String? { projectPath.map { ($0 as NSString).lastPathComponent } }

    /// Display label: "mainRepo › worktree" for worktrees, else the project name.
    var projectLabel: String? {
        guard let name = projectName else { return nil }
        if isWorktree, let group = projectGroup, group != name { return "\(group) › \(name)" }
        return name
    }

    var source: String? { lock?.source }

    /// True when we have any provenance (a lockfile entry).
    var isTracked: Bool { lock?.source != nil }

    /// True when update detection via GitHub tree SHA is possible.
    var canCheckUpdate: Bool { lock?.source != nil && lock?.skillPath != nil && lock?.skillFolderHash != nil }

    /// Repo folder containing the skill — parent of `skillPath` (which points to SKILL.md).
    /// Returns "" when SKILL.md is at the repo root (handled as the root tree).
    var repoFolder: String? {
        guard let p = lock?.skillPath, !p.isEmpty else { return nil }
        return (p as NSString).deletingLastPathComponent
    }

    /// Best available installed identifier (git tree SHA preferred, else content hash).
    var installedSha: String? { lock?.skillFolderHash ?? lock?.computedHash }

    /// Short "version" string for the UI.
    var shortVersion: String? {
        guard let s = installedSha else { return nil }
        return String(s.prefix(7))
    }

    /// GitHub repo page (sourceURL minus a trailing .git, else built from source).
    var githubURL: URL? {
        if let u = lock?.sourceURL, !u.isEmpty {
            let cleaned = u.hasSuffix(".git") ? String(u.dropLast(4)) : u
            return URL(string: cleaned)
        }
        if let src = lock?.source { return URL(string: "https://github.com/\(src)") }
        return nil
    }

    /// skills.sh page — verified pattern is `https://skills.sh/{source}`.
    var skillsShURL: URL? {
        guard let src = lock?.source else { return URL(string: "https://skills.sh") }
        return URL(string: "https://skills.sh/\(src)")
    }

    /// Dedup key for update checks: unique per (source, ref, folder).
    var updateKey: String? {
        guard let src = lock?.source, let folder = repoFolder else { return nil }
        return "\(src)@\(lock?.ref ?? "")::\(folder)"
    }
}
