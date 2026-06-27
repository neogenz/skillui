import Foundation

/// Recursively discovers "projects" under a root — directories that hold project-scope skills
/// (an agent skills dir or a `skills-lock.json`). Depth-capped and skips heavy/uninteresting
/// directories so scanning a broad root (e.g. ~) stays fast. Does not descend into a project
/// once found, and never follows symlinked directories (avoids loops).
struct ProjectFinder: Sendable {
    var root: String
    var maxDepth: Int = 6
    var homeOverrideForTesting: String? = nil

    static let skip: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", ".build", "build",
        "DerivedData", "Pods", "dist", "out", ".next", ".nuxt", ".cache", ".venv", "venv",
        "__pycache__", ".gradle", ".npm", ".cargo", "vendor", ".Trash", "target", ".terraform",
        // Global agent config dirs — the global skills live here but they are NOT projects.
        ".claude", ".codex", ".cursor", ".agents", ".config", ".vibe", ".hermes",
        ".deepagents", ".gemini", ".local",
        // macOS TCC-protected / personal folders — NEVER enter these (they'd trigger a privacy
        // prompt and projects don't live there). Skipped by name so we never list their contents.
        "Library", "Applications", "Documents", "Desktop", "Downloads", "Music", "Pictures",
        "Movies", "Public", "Mobile Documents", "Creative Cloud Files",
    ]
    static let markers = [".agents/skills", ".claude/skills", ".codex/skills", ".cursor/skills"]
    /// Agent worktree containers that live INSIDE a project, under otherwise-skipped dot dirs.
    /// Claude Code / Codex create git worktrees here, and those are exactly the ones that often
    /// miss their skills — so descend into them explicitly even though `.claude` etc. are skipped.
    static let worktreeContainers = [".claude/worktrees", ".codex/worktrees", ".cursor/worktrees"]

    private var homePath: String { homeOverrideForTesting ?? FileManager.default.homeDirectoryForCurrentUser.path }

    func find() -> [String] {
        let start = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        var out: [String] = []
        walk(start, depth: 0, into: &out)
        return out.sorted()
    }

    private func isProject(_ dir: URL) -> Bool {
        // Home holds the GLOBAL skill dirs (~/.claude/skills, ~/.agents/skills, …); it is not a project.
        if dir.path == homePath { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("skills-lock.json").path) { return true }
        return Self.markers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    private func walk(_ dir: URL, depth: Int, into out: inout [String]) {
        if depth > maxDepth { return }
        if isProject(dir) {
            out.append(dir.path)
            walkAgentWorktrees(of: dir, depth: depth, into: &out)   // its worktrees live under skipped dot dirs
            return                                                  // don't descend into normal project contents
        }
        guard depth < maxDepth,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []) else { return }
        for e in entries {
            if Self.skip.contains(e.lastPathComponent) { continue }
            let vals = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }
            walk(e, depth: depth + 1, into: &out)
        }
    }

    /// Enumerate a project's agent worktrees (`.claude/worktrees/*`, …) — the general walk skips
    /// those dot dirs, but the worktrees inside are real projects (each with its own lockfile).
    private func walkAgentWorktrees(of project: URL, depth: Int, into out: inout [String]) {
        let fm = FileManager.default
        for container in Self.worktreeContainers {
            let dir = project.appendingPathComponent(container)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            else { continue }
            for e in entries {
                let vals = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard vals?.isDirectory == true, vals?.isSymbolicLink != true else { continue }
                walk(e, depth: depth + 1, into: &out)
            }
        }
    }
}
