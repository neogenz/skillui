import Foundation

/// Detects whether a project directory is a git worktree and, if so, which main repo it
/// belongs to. A worktree's `.git` is a FILE containing `gitdir: <main>/.git/worktrees/<name>`,
/// whereas a normal repo's `.git` is a directory. Used to group worktrees under their main repo.
enum GitInfo {
    struct Meta: Sendable, Equatable {
        var name: String          // the project dir name
        var mainRepo: String?     // main repo name when this is a worktree
        var isWorktree: Bool
    }

    static func meta(for root: String) -> Meta {
        let name = (root as NSString).lastPathComponent
        let gitPath = (root as NSString).appendingPathComponent(".git")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
        guard exists, !isDir.boolValue else {
            return Meta(name: name, mainRepo: nil, isWorktree: false)   // dir .git = normal repo (or none)
        }

        // `.git` is a file → worktree. Parse "gitdir: <main>/.git/worktrees/<wt>".
        if let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
           let r = content.range(of: "gitdir:") {
            let target = content[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let wt = target.range(of: "/.git/worktrees/") {
                let mainPath = String(target[..<wt.lowerBound])
                return Meta(name: name, mainRepo: (mainPath as NSString).lastPathComponent, isWorktree: true)
            }
        }
        return Meta(name: name, mainRepo: nil, isWorktree: true)
    }
}
