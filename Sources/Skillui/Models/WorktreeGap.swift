import Foundation

/// A project/worktree whose `skills-lock.json` declares skills that aren't installed on disk —
/// the classic "fresh git worktree, skills never hydrated" case. Fixable by re-running the
/// lockfile install (`skills experimental_install`) in that folder, which restores them for the
/// agents the lockfile was built for.
struct WorktreeGap: Identifiable, Sendable, Equatable {
    let path: String          // project / worktree root
    let name: String          // worktree dir name
    let group: String         // main repo name (for grouping + labels)
    let isWorktree: Bool
    let missing: [String]     // skill names present in the lockfile but not on disk
    let expected: Int         // total skills the lockfile declares

    var id: String { path }
    var installedCount: Int { max(0, expected - missing.count) }

    /// "mainRepo › worktree" for a worktree, else the bare dir name.
    var label: String {
        isWorktree && group != name ? "\(group) › \(name)" : name
    }
}
