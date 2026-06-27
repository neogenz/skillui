import Foundation

/// Enumerates a project's skills directly from disk (fast, and gives the symlink info the
/// `skills list` CLI doesn't): for each skill it records which agent dirs hold it and whether
/// it's project-local or a symlink into the global install. Joins the project `skills-lock.json`
/// by name for source/version.
struct FilesystemScanner: Sendable {
    let globalRoots: [String]

    static let agentDirs: [(rel: String, label: String)] = [
        (".agents/skills", "Shared"),
        (".claude/skills", "Claude Code"),
        (".codex/skills", "Codex"),
        (".cursor/skills", "Cursor"),
    ]

    func scan(projectRoots: [String]) -> [Skill] {
        projectRoots.flatMap { scanProject($0) }
    }

    func scanProject(_ root: String) -> [Skill] {
        let fm = FileManager.default
        let lock = LockfileParser.read(LockfileParser.projectLockURL(projectRoot: root))
        let meta = GitInfo.meta(for: root)

        struct Acc { var canonicalPath: String; var agents: Set<String> }
        var byName: [String: Acc] = [:]

        for (rel, label) in Self.agentDirs {
            let dir = URL(fileURLWithPath: root).appendingPathComponent(rel)
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            else { continue }
            for e in entries {
                let name = e.lastPathComponent
                if name.hasPrefix(".") { continue }
                let vals = try? e.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard vals?.isDirectory == true || vals?.isSymbolicLink == true else { continue }
                var acc = byName[name] ?? Acc(canonicalPath: e.path, agents: [])
                acc.agents.insert(label)
                if rel == ".agents/skills" { acc.canonicalPath = e.path }   // prefer the shared dir
                byName[name] = acc
            }
        }

        return byName.map { name, acc in
            let link = LinkClassifier.classify(path: acc.canonicalPath, scope: .project, globalRoots: globalRoots)
            return Skill(name: name, path: acc.canonicalPath, scope: .project,
                         agents: Array(acc.agents).sorted(), projectPath: root,
                         lock: lock[name], linkType: link,
                         projectGroup: meta.mainRepo ?? meta.name, isWorktree: meta.isWorktree)
        }
        .sorted { $0.name < $1.name }
    }
}
