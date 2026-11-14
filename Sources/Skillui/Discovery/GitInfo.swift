import Foundation

/// Detects whether a project directory is a git worktree and, if so, which main repo it
/// belongs to. A worktree's `.git` is a FILE containing `gitdir: <main>/.git/worktrees/<name>`,
/// whereas a normal repo's `.git` is a directory. Used to group worktrees under their main repo.
enum GitInfo {
    struct Meta: Sendable, Equatable {
        var name: String          // the project dir name
        var mainRepo: String?     // main repo name when this is a worktree
        var isWorktree: Bool
        var isRemoved = false     // leftover dir of a worktree git already removed (no `.git` left)
    }

    static func meta(for root: String) -> Meta {
        let name = (root as NSString).lastPathComponent
        let gitPath = (root as NSString).appendingPathComponent(".git")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir)
        if !exists {
            // `git worktree remove` can leave ignored files behind (build output, skills-lock.json).
            // Claude Code puts worktrees in `<repo>/.claude/worktrees/<name>`, so the layout names the repo.
            let parent = (root as NSString).deletingLastPathComponent
            let dotClaude = (parent as NSString).deletingLastPathComponent
            if (parent as NSString).lastPathComponent == "worktrees",
               (dotClaude as NSString).lastPathComponent == ".claude" {
                let repo = ((dotClaude as NSString).deletingLastPathComponent as NSString).lastPathComponent
                return Meta(name: name, mainRepo: repo, isWorktree: true, isRemoved: true)
            }
        }
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
