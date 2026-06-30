import Foundation

/// One skill a `skills-lock.json` declares but that isn't installed on disk, carrying enough source
/// info to decide whether `skills add` can clone it. `package`/`isInstallable` are resolved ONCE from
/// the lockfile entry (`LockEntry.installPackage` / `isBlockedSource`) so the install plan and the
/// classification never disagree.
struct MissingSkill: Sendable, Equatable {
    let name: String
    let package: String?      // arg for `skills add`; nil when the lockfile records no source
    let isInstallable: Bool

    /// Why a blocked skill can't be auto-installed — shown verbatim in the UI.
    var blockedReason: String {
        if let package { return "source '\(package)' isn't a git repository" }
        return "no source recorded in the lockfile"
    }
}

/// A project/worktree whose `skills-lock.json` declares skills that aren't installed on disk —
/// the classic "fresh git worktree, skills never hydrated" case. Installable skills are restored by
/// running the lockfile install (`skills experimental_install`, or per-source `skills add` when some
/// of the declared sources can't be cloned); blocked skills can't be auto-installed at all.
struct WorktreeGap: Identifiable, Sendable, Equatable {
    let path: String              // project / worktree root
    let name: String              // worktree dir name
    let group: String             // main repo name (for grouping + labels)
    let isWorktree: Bool
    let entries: [MissingSkill]   // declared in the lockfile but not on disk (sorted by name)
    let expected: Int             // total skills the lockfile declares

    var id: String { path }

    /// Skill names — kept for the many call sites that only need the count or the name list.
    var missing: [String] { entries.map(\.name) }
    /// Skills `skills add` can clone — the only ones the install button acts on.
    var installable: [MissingSkill] { entries.filter(\.isInstallable) }
    /// Skills whose source isn't a cloneable git repo — surfaced, never auto-installed.
    var blocked: [MissingSkill] { entries.filter { !$0.isInstallable } }

    var installedCount: Int { max(0, expected - entries.count) }

    /// "mainRepo › worktree" for a worktree, else the bare dir name.
    var label: String {
        isWorktree && group != name ? "\(group) › \(name)" : name
    }
}
