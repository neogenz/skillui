import Foundation

/// Recursively discovers "projects" under a root — directories that hold project-scope skills
/// (an agent skills dir or a `skills-lock.json`). Depth-capped and skips heavy/uninteresting
/// directories so scanning a broad root (e.g. ~) stays fast. Does not descend into a project
/// once found, and never follows symlinked directories (avoids loops).
struct ProjectFinder: Sendable {
    var root: String
    var maxDepth: Int = 6

    static let skip: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "Library", "Applications", ".build", "build",
        "DerivedData", "Pods", "dist", "out", ".next", ".nuxt", ".cache", ".venv", "venv",
        "__pycache__", ".gradle", ".npm", ".cargo", "vendor", ".Trash", "target", ".terraform",
    ]
    static let markers = [".agents/skills", ".claude/skills", ".codex/skills", ".cursor/skills"]

    func find() -> [String] {
        let start = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        var out: [String] = []
        walk(start, depth: 0, into: &out)
        return out.sorted()
    }

    private func isProject(_ dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("skills-lock.json").path) { return true }
        return Self.markers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    private func walk(_ dir: URL, depth: Int, into out: inout [String]) {
        if depth > maxDepth { return }
        if isProject(dir) { out.append(dir.path); return }   // leaf: don't descend into a project
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
}
